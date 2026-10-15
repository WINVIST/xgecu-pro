import Foundation

struct ChipCatalog {
    let names: [String]

    init(names: [String]) {
        self.names = Array(Set(names.filter { !$0.isEmpty })).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    func matching(_ query: String) -> [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return names }
        return names.filter { $0.localizedCaseInsensitiveContains(text) }
    }
}

final class FavoriteChipStore {
    private let defaults: UserDefaults
    private let key = "favoriteChipNames"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String] {
        ChipCatalog(names: defaults.stringArray(forKey: key) ?? []).names
    }

    func save(_ names: [String]) {
        defaults.set(ChipCatalog(names: names).names, forKey: key)
    }
}
