// Development browser rendering only. This module is excluded from release builds.
import {
  emptyBuffer,
  type BufferReply,
  type DesktopBridge,
  type OperationEvent,
  type Settings,
} from "./types";
const names = [
  "MX25L51245G@SOIC16",
  "MX25L51245G@WSON8",
  "W25Q128JV@SOIC8",
  "W25Q256JV@SOIC16",
  "AT28C256@DIP28",
];
export function createPreviewBridge(): DesktopBridge {
  const fixture =
    new URLSearchParams(location.search).get("preview") || "start";
  let settings: Settings = {
    databasePath: "",
    favorites: fixture.includes("favorites")
      ? ["MX25L51245G@SOIC16", "W25Q128JV@SOIC8"]
      : [],
    theme: new URLSearchParams(location.search).get("preview")?.includes("dark")
      ? "dark"
      : "light",
  };
  let buffer: BufferReply = { ...emptyBuffer };
  let emit: (e: OperationEvent) => void = () => {};
  const bytes = Array.from({ length: 256 }, (_, i) => i);
  let undo = false;
  return {
    preview: true,
    settings: async () => settings,
    saveSettings: async (s) => (settings = s),
    programmer: async (r) => {
      emit({
        stage: r.operation === "search" ? "Loading chip catalog" : r.operation,
      });
      if (r.operation === "connect")
        return { ok: true, model: "T76", fw: "00.1.07", link: "hs" };
      if (r.operation === "search")
        return {
          ok: true,
          n: names.length,
          hits: r.limit === 0 ? [] : names,
          more: r.limit === 0,
        };
      if (r.operation === "describe")
        return {
          ok: true,
          name: r.chip || names[0],
          package: (r.chip || names[0]).split("@")[1],
          pins: 16,
          code_bytes: 67108864,
          data_bytes: 0,
          data2_bytes: 0,
          page_bytes: 256,
          chip_id: "C2201A",
          blank_value: "FF",
          can_erase: true,
        };
      if (r.operation === "autodetect")
        return { ok: true, id: "C2201A", matches: [names[0]], n: 1 };
      if (r.operation === "check")
        return { ok: true, chip_id_checked: true, pins_checked: false };
      if (r.operation === "usb_diagnose")
        return {
          ok: true,
          report: {
            passed: true,
            profile: "baseline",
            link: "High",
            opening: { interface_claimed: true },
            probes: [0, 100, 1000, 3000].map((idle_ms) => ({
              idle_ms,
              firmware: "00.1.07",
            })),
          },
        };
      return { ok: true, stable: true, matches: true, blank: true };
    },
    prepare: async (chip, file) => ({
      token: "browser-preview-token",
      chip,
      file,
      bytes: 67108864,
    }),
    commit: async () => ({ ok: true, op: "write" }),
    cancel: async () => {},
    buffer: async (r) => {
      if (r.operation === "open")
        buffer = {
          size: fixture.includes("hex")
            ? fixture.includes("large")
              ? 1140850688
              : 256
            : 67108864,
          offset: 0,
          bytes: [...bytes],
          sha256:
            "7a122af3a741836e01f4b935b17cbde351e5a0288928f75519bb7c74c8b0b412e",
          source: r.file,
          originChip: r.originChip,
          dirty: fixture.includes("hex"),
          canUndo: fixture.includes("hex"),
          canRedo: false,
        };
      if (r.operation === "page")
        buffer = { ...buffer, offset: r.offset || 0, bytes: [...bytes] };
      if (["edit", "fill", "copy"].includes(r.operation)) {
        undo = true;
        buffer = { ...buffer, dirty: true, canUndo: true, bytes: [...bytes] };
        if (r.operation === "edit" && r.offset !== undefined)
          buffer.bytes[r.offset % 256] = r.value || 0;
      }
      if (r.operation === "undo")
        buffer = { ...buffer, dirty: false, canUndo: false, canRedo: undo };
      if (r.operation === "redo")
        buffer = { ...buffer, dirty: true, canUndo: true, canRedo: false };
      if (r.operation === "save")
        buffer = { ...buffer, dirty: false, savedPath: r.file };
      if (r.operation === "find_hex" || r.operation === "find_ascii")
        return { ...buffer, foundOffset: 0x100 };
      if (r.operation === "compare")
        return { ...buffer, matches: true, otherBytes: buffer.size };
      return { ...buffer };
    },
    open: async (title, directory) =>
      directory
        ? "C:\\Preview\\Database"
        : `C:\\Preview\\${title.includes("Firmware") ? "router-firmware.bin" : "dump.bin"}`,
    save: async (_, path) => `C:\\Preview\\${path}`,
    inspectFile: async () => ({ bytes: 67108864 }),
    saveText: async () => {},
    allowClose: async () => {},
    subscribe: async (callback) => {
      emit = callback;
      return () => {
        emit = () => {};
      };
    },
  };
}
