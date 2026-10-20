import { beforeEach, describe, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({
  invoke: vi.fn(),
  isTauri: vi.fn(() => true),
  listen: vi.fn(),
  open: vi.fn(),
  save: vi.fn(),
}));
vi.mock("@tauri-apps/api/core", () => ({
  invoke: mocks.invoke,
  isTauri: mocks.isTauri,
}));
vi.mock("@tauri-apps/api/event", () => ({ listen: mocks.listen }));
vi.mock("@tauri-apps/plugin-dialog", () => ({
  open: mocks.open,
  save: mocks.save,
}));
import { createBridge } from "./bridge";

beforeEach(() => {
  vi.clearAllMocks();
  mocks.isTauri.mockReturnValue(true);
});
describe("native typed adapter", () => {
  it("sends structured operations and explicit snapshot tokens to native commands", async () => {
    const bridge = await createBridge();
    await bridge.programmer({
      operation: "read",
      chip: "MX25@SOIC16",
      file: "C:\\Δ\\dump.bin",
      database: "trusted",
    });
    expect(mocks.invoke).toHaveBeenLastCalledWith("programmer_run", {
      request: {
        operation: "read",
        chip: "MX25@SOIC16",
        file: "C:\\Δ\\dump.bin",
        database: "trusted",
      },
    });
    await bridge.prepare("MX25", "firmware.bin", "trusted");
    expect(mocks.invoke).toHaveBeenLastCalledWith("prepare_program", {
      chip: "MX25",
      file: "firmware.bin",
      database: "trusted",
    });
    await bridge.commit("snapshot-token");
    expect(mocks.invoke).toHaveBeenLastCalledWith("commit_program", {
      token: "snapshot-token",
    });
    await bridge.cancel("snapshot-token");
    expect(mocks.invoke).toHaveBeenLastCalledWith("cancel_program", {
      token: "snapshot-token",
    });
  });
  it("propagates helper failures without replacing a native adapter with fixtures", async () => {
    mocks.invoke.mockRejectedValueOnce({
      code: "usb_open",
      message: "No T76 connected",
    });
    const bridge = await createBridge();
    expect(bridge.preview).toBe(false);
    await expect(bridge.programmer({ operation: "connect" })).rejects.toEqual({
      code: "usb_open",
      message: "No T76 connected",
    });
  });
  it("returns cancelled native file dialogs without opening a file", async () => {
    mocks.open.mockResolvedValueOnce(null);
    mocks.save.mockResolvedValueOnce(null);
    const bridge = await createBridge();
    expect(await bridge.open("Choose Firmware")).toBeNull();
    expect(await bridge.save("Save Buffer", "buffer.bin")).toBeNull();
    expect(mocks.invoke).not.toHaveBeenCalled();
  });
  it("forwards live progress and releases both subscriptions on unmount", async () => {
    const off = vi.fn();
    const offClose = vi.fn();
    mocks.listen.mockResolvedValueOnce(off).mockResolvedValueOnce(offClose);
    const bridge = await createBridge();
    const event = vi.fn();
    const close = vi.fn();
    const unsubscribe = await bridge.subscribe(event, close);
    expect(mocks.listen.mock.calls.map((call) => call[0])).toEqual([
      "operation-event",
      "close-requested",
    ]);
    mocks.listen.mock.calls[0][1]({
      payload: { stage: "write", progress: { done: 512, total: 1024 } },
    });
    expect(event).toHaveBeenCalledWith({
      stage: "write",
      progress: { done: 512, total: 1024 },
    });
    mocks.listen.mock.calls[1][1]();
    expect(close).toHaveBeenCalledOnce();
    unsubscribe();
    expect(off).toHaveBeenCalledOnce();
    expect(offClose).toHaveBeenCalledOnce();
  });
});
