import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open, save } from "@tauri-apps/plugin-dialog";
import type { DesktopBridge, OperationEvent } from "./types";

const nativeBridge: DesktopBridge = {
  preview: false,
  settings: () => invoke("get_settings"),
  saveSettings: (settings) => invoke("save_settings", { settings }),
  programmer: (request) => invoke("programmer_run", { request }),
  prepare: (chip, file, database) =>
    invoke("prepare_program", { chip, file, database }),
  commit: (token) => invoke("commit_program", { token }),
  cancel: (token) => invoke("cancel_program", { token }),
  buffer: (request) => invoke("buffer_command", { request }),
  open: async (title, directory = false) => {
    const path = await open({ title, directory, multiple: false });
    return typeof path === "string" ? path : null;
  },
  save: (title, defaultPath) => save({ title, defaultPath }),
  inspectFile: (file) => invoke("inspect_file", { file }),
  saveText: (file, contents) => invoke("save_text_file", { file, contents }),
  allowClose: () => invoke("allow_close", { discard: true }),
  subscribe: async (callback, close) => {
    const off = await listen<OperationEvent>("operation-event", (e) =>
      callback(e.payload),
    );
    try {
      const offClose = await listen("close-requested", close);
      return () => {
        off();
        offClose();
      };
    } catch (e) {
      off();
      throw e;
    }
  },
};

export async function createBridge(): Promise<DesktopBridge> {
  if (isTauri()) return nativeBridge;
  // Vite removes this development-only branch and its separate fixture chunk
  // from production builds. A production webview can never substitute USB data.
  if (import.meta.env.DEV)
    return (await import("./preview")).createPreviewBridge();
  throw new Error(
    "Open XGecu Pro from the installed desktop application. The browser preview is available only in development.",
  );
}
