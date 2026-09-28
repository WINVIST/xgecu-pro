import Foundation

struct MiniProFailure: LocalizedError {
    let message: String
    let hint: String?

    var errorDescription: String? {
        hint.map { "\(message)\n\($0)" } ?? message
    }
}

/// Runs the bundled Rust CLI without a shell. The CLI writes one JSON result to
/// stdout and newline-delimited progress/warnings to stderr.
final class MiniProRunner {
    static var bundledDatabasePath: String? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("ChipDatabase") else {
            return nil
        }
        let files = FileManager.default
        guard files.fileExists(atPath: root.appendingPathComponent("InfoICT76.dll").path),
              files.fileExists(atPath: root.appendingPathComponent("algoT76").path)
                || files.fileExists(atPath: root.appendingPathComponent("algorithm.xml").path) else {
            return nil
        }
        return root.path
    }

    func run(
        _ arguments: [String],
        databasePath: String,
        onEvent: @escaping ([String: Any]) -> Void,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("minipro"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            completion(.failure(MiniProFailure(
                message: "The bundled minipro executable is missing.",
                hint: "Rebuild the project in Xcode so the build phase can add the Rust helper."
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = executable
            let resolvedDatabase = databasePath.isEmpty ? Self.bundledDatabasePath : databasePath
            process.arguments = ["--json"] + (resolvedDatabase.map { ["--db", $0] } ?? []) + arguments
            var environment = ProcessInfo.processInfo.environment
            for key in ["MINIPRO_VENDOR_URL", "MINIPRO_DB_URL", "MINIPRO_DB_DIR", "MINIPRO_KEEP_BITSTREAM"] {
                environment.removeValue(forKey: key)
            }
            environment["MINIPRO_REQUIRE_MODEL"] = "T76"
            environment["MINIPRO_REQUIRE_CHIP_ID"] = "1"
            environment["MINIPRO_TRUST_PINNED_DB_ONLY"] = "1"
            process.environment = environment
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            let stderrDone = DispatchGroup()
            stderrDone.enter()
            DispatchQueue.global(qos: .utility).async {
                var pending = Data()
                while true {
                    let chunk = stderr.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0a) {
                        let line = Data(pending[..<newline])
                        pending.removeSubrange(...newline)
                        if let event = Self.decode(line) {
                            DispatchQueue.main.async { onEvent(event) }
                        }
                    }
                }
                if let event = Self.decode(pending) {
                    DispatchQueue.main.async { onEvent(event) }
                }
                stderrDone.leave()
            }

            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            stderrDone.wait()
            let result = Self.decode(output)
            DispatchQueue.main.async {
                guard let result else {
                    completion(.failure(MiniProFailure(
                        message: "minipro did not return a JSON result.",
                        hint: "Exit status: \(process.terminationStatus)."
                    )))
                    return
                }
                if result["ok"] as? Bool == true && process.terminationStatus == 0 {
                    completion(.success(result))
                } else {
                    completion(.failure(MiniProFailure(
                        message: result["msg"] as? String ?? "The minipro operation failed.",
                        hint: result["hint"] as? String
                    )))
                }
            }
        }
    }

    private static func decode(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else { return nil }
        return object
    }
}
