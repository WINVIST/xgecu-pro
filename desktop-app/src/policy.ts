import type { AppFailure, ChipDetails, DiagnosticReport } from "./types";
export const MAX_IMAGE = 2 * 1024 ** 3;
export const basename = (path: string) => path.split(/[\\/]/).pop() || path;
export const hex = (value: number, width = 0) =>
  value.toString(16).toUpperCase().padStart(width, "0");
export function parseHex(input: string): number {
  const text = input.trim().replace(/^0x/i, "");
  if (!/^[0-9a-f]+$/i.test(text))
    throw new Error("Enter a valid hexadecimal address or byte value.");
  const value = Number.parseInt(text, 16);
  if (!Number.isSafeInteger(value))
    throw new Error("The hexadecimal value is too large.");
  return value;
}
export function canRead(
  chip: string,
  details: ChipDetails | null,
  connected: boolean,
): boolean {
  return !!(
    connected &&
    details &&
    details.name === chip &&
    details.package &&
    details.pins > 0 &&
    details.code_bytes > 0 &&
    details.code_bytes <= MAX_IMAGE &&
    details.data_bytes >= 0 &&
    details.data2_bytes >= 0 &&
    details.page_bytes >= 0
  );
}
export function canWrite(
  chip: string,
  details: ChipDetails | null,
  connected: boolean,
): boolean {
  return canRead(chip, details, connected) && !!details?.chip_id;
}
export function chipDetails(result: unknown): ChipDetails {
  const d = result as ChipDetails;
  if (
    !d ||
    typeof d.name !== "string" ||
    typeof d.package !== "string" ||
    !["pins", "code_bytes", "data_bytes", "data2_bytes", "page_bytes"].every(
      (k) => Number.isSafeInteger((d as unknown as Record<string, unknown>)[k]),
    ) ||
    typeof d.blank_value !== "string" ||
    typeof d.can_erase !== "boolean"
  )
    throw new Error("The chip database returned incomplete details.");
  return d;
}
export function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "object" && error && "message" in error) {
    const e = error as AppFailure;
    return e.message + (e.hint ? ` ${e.hint}` : "");
  }
  return typeof error === "string" ? error : "The operation could not finish.";
}
export function byteCount(bytes: number): string {
  return `${new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 }).format(bytes / (bytes >= 1024 ** 3 ? 1024 ** 3 : bytes >= 1024 ** 2 ? 1024 ** 2 : bytes >= 1024 ? 1024 : 1))} ${bytes >= 1024 ** 3 ? "GiB" : bytes >= 1024 ** 2 ? "MiB" : bytes >= 1024 ? "KiB" : "bytes"}`;
}
export function usbSummary(report: DiagnosticReport) {
  const claimed = report.opening?.interface_claimed === true;
  const found = !!(
    report.link ||
    report.bos_hex ||
    claimed ||
    report.opening?.configurations?.length
  );
  const probes = report.probes || [];
  const successful = probes.filter(
    (p) => !p.error && typeof p.firmware === "string",
  );
  const versions = new Set(successful.map((p) => p.firmware));
  const complete =
    probes.length === 4 &&
    successful.length === 4 &&
    versions.size === 1 &&
    probes.every((p, i) => p.idle_ms === [0, 100, 1000, 3000][i]);
  const passed =
    report.passed === true &&
    complete &&
    claimed &&
    !report.error &&
    !report.restore_error;
  let title = "Diagnostic report is incomplete";
  let advice =
    "Start a new test. If the report remains incomplete, save it with the app version for troubleshooting.";
  if (passed) {
    title = "USB connection test passed";
    advice =
      "The T76 replied before and after idle pauses. Close this window and use Connect / Refresh. Chip reads and programming are checked by their own readback tests.";
  } else if (report.restore_error) {
    title = "USB settings could not be restored";
    advice =
      "Unplug the cable from the T76, then reconnect it before any further operation. Save this report if the problem repeats.";
  } else if (report.error?.includes("connect exactly one T76")) {
    title = "More than one T76 is connected";
    advice = "Leave one programmer connected, then start a new test.";
  } else if (report.error?.includes("no T76 connected")) {
    title = "T76 was not found";
    advice =
      "Connect the programmer with a data-capable USB cable and check its power light. Try another port or cable, then start a new test.";
  } else if (report.error?.includes("requires a confirmed SuperSpeed link")) {
    title = "USB sleep experiment is unavailable";
    advice =
      "This optional experiment requires a measured USB 3 link. Use the standard connection test for this connection.";
  } else if (found && !claimed) {
    title = "T76 was found, but its interface did not open";
    advice =
      "Close other programmer apps. Check WinUSB on Windows or the T76 udev rule on Linux. Unplug the cable from the T76 and reconnect it, then start a new test.";
  } else if (claimed && probes.length) {
    title = "Communication with the T76 failed";
    advice =
      "Try another data cable or USB port. If using a hub or dock, compare a direct connection. Save the reports for both connections.";
  } else if (report.error) {
    title = "USB connection test could not finish";
    advice =
      "Save the report and check the technical details. Reconnect the T76 before starting a new test.";
  }
  return {
    passed,
    title,
    advice,
    found,
    claimed,
    complete,
    successful: successful.length,
    firmware:
      versions.size === 1
        ? [...versions][0]
        : versions.size
          ? "Replies differ"
          : "Not reported",
    speed:
      (
        {
          Super: "USB 3 · SuperSpeed",
          SuperPlus: "USB 3 · SuperSpeed Plus",
          High: "USB 2 · High Speed",
          Full: "USB Full Speed",
          Low: "USB Low Speed",
        } as Record<string, string>
      )[report.link || ""] || "Not reported by the operating system",
  };
}
