import { act, renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { createElement, StrictMode, type PropsWithChildren } from "react";
import { useApp } from "./useApp";
import {
  emptyBuffer,
  type DesktopBridge,
  type ProgrammerResult,
} from "./types";

const details = {
  name: "MX25L51245G@SOIC16",
  package: "SOIC16",
  pins: 16,
  code_bytes: 67108864,
  data_bytes: 0,
  data2_bytes: 0,
  page_bytes: 256,
  chip_id: "C2201A",
  blank_value: "FF",
  can_erase: true,
};
function testBridge() {
  let closeRequest: () => void = () => {};
  const bridge: DesktopBridge = {
    preview: false,
    settings: vi.fn(async () => ({
      databasePath: "trusted-db",
      favorites: [],
      theme: "light" as const,
    })),
    saveSettings: vi.fn(async (settings) => settings),
    programmer: vi.fn<DesktopBridge["programmer"]>(async (request) =>
      request.operation === "connect"
        ? { model: "T76", fw: "1.07", link: "hs" }
        : request.operation === "describe"
          ? details
          : request.operation === "search"
            ? {
                n: 2,
                hits: request.limit === 0 ? [] : [details.name, "OTHER@DIP8"],
                more: request.limit === 0,
              }
            : {},
    ),
    prepare: vi.fn(async (chip, file) => ({
      token: "private-snapshot",
      chip,
      file,
      bytes: 67108864,
    })),
    commit: vi.fn(async () => ({ ok: true, op: "write" })),
    cancel: vi.fn(async () => {}),
    buffer: vi.fn(async (request) => ({
      ...emptyBuffer,
      size: 256,
      source: request.file,
      bytes:
        request.operation === "open" || request.operation === "page"
          ? [0, 1, 2, 3]
          : [],
      dirty: false,
    })),
    open: vi.fn(async () => "/firmware/source.bin"),
    inspectFile: vi.fn(async () => ({ bytes: 67108864 })),
    save: vi.fn(async () => "/firmware/output.bin"),
    saveText: vi.fn(async () => {}),
    allowClose: vi.fn(async () => {}),
    subscribe: vi.fn(async (_event, close) => {
      closeRequest = close;
      return () => {};
    }),
  };
  return { bridge, close: () => closeRequest() };
}
async function mounted(bridge: DesktopBridge) {
  const hook = renderHook(() => useApp(bridge));
  await waitFor(() =>
    expect(hook.result.current.settings.databasePath).toBe("trusted-db"),
  );
  return hook;
}
async function ready(bridge: DesktopBridge) {
  const hook = await mounted(bridge);
  await act(() => hook.result.current.connect());
  await act(() => hook.result.current.selectChip(details.name));
  await act(() => hook.result.current.chooseFirmware());
  return hook;
}

describe("platform-specific startup connection check", () => {
  it("checks native Windows once even when Strict Mode replays startup effects", async () => {
    vi.spyOn(navigator, "platform", "get").mockReturnValue("Win32");
    const { bridge } = testBridge();
    const hook = renderHook(() => useApp(bridge), {
      wrapper: ({ children }: PropsWithChildren) =>
        createElement(StrictMode, null, children),
    });
    await waitFor(() => expect(hook.result.current.connected).toBe(true));
    hook.rerender();
    expect(bridge.programmer).toHaveBeenCalledTimes(1);
    expect(bridge.programmer).toHaveBeenCalledWith(
      expect.objectContaining({ operation: "connect" }),
    );
    expect(bridge.prepare).not.toHaveBeenCalled();
  });
  it.each(["Linux x86_64", "MacIntel"])(
    "keeps %s startup unchanged",
    async (platform) => {
      vi.spyOn(navigator, "platform", "get").mockReturnValue(platform);
      const { bridge } = testBridge();
      await mounted(bridge);
      expect(bridge.programmer).not.toHaveBeenCalled();
    },
  );
  it("does not check hardware from a Windows browser preview", async () => {
    vi.spyOn(navigator, "platform", "get").mockReturnValue("Win32");
    const { bridge } = testBridge();
    await mounted({ ...bridge, preview: true });
    expect(bridge.programmer).not.toHaveBeenCalled();
  });
});
describe("programming confirmation and operation exclusion", () => {
  it("prepares a private snapshot, locks conflicting changes, and cancels without writing", async () => {
    const { bridge } = testBridge();
    const { result } = await ready(bridge);
    await act(() => result.current.program());
    expect(bridge.prepare).toHaveBeenCalledWith(
      details.name,
      "/firmware/source.bin",
      "trusted-db",
    );
    expect(result.current.confirmation?.title).toBe(`Program ${details.name}?`);
    expect(result.current.locked).toBe(true);
    await act(() => result.current.chooseFirmware());
    await act(() => result.current.connect());
    await act(() => result.current.selectChip("OTHER"));
    expect(bridge.open).toHaveBeenCalledTimes(1);
    expect(result.current.chip).toBe(details.name);
    await act(() => result.current.resolve(false));
    expect(bridge.cancel).toHaveBeenCalledExactlyOnceWith("private-snapshot");
    expect(bridge.commit).not.toHaveBeenCalled();
    expect(result.current.locked).toBe(false);
  });
  it("commits only the prepared token after explicit acceptance", async () => {
    const { bridge } = testBridge();
    const { result } = await ready(bridge);
    await act(() => result.current.program());
    expect(bridge.commit).not.toHaveBeenCalled();
    await act(() => result.current.resolve(true));
    expect(bridge.commit).toHaveBeenCalledExactlyOnceWith("private-snapshot");
    expect(bridge.cancel).not.toHaveBeenCalled();
    expect(result.current.status).toMatch(
      /completed and verified by a readback/,
    );
  });
  it("does not offer confirmation or mutation after failed ID preflight", async () => {
    const { bridge } = testBridge();
    vi.mocked(bridge.prepare).mockRejectedValue({
      code: "chip_id_mismatch",
      message: "Chip ID differs from the selected entry.",
    });
    const { result } = await ready(bridge);
    await act(() => result.current.program());
    expect(result.current.confirmation).toBeNull();
    expect(result.current.status).toContain("Chip ID differs");
    expect(bridge.commit).not.toHaveBeenCalled();
  });
  it("retains a cancellable pending confirmation if snapshot cleanup fails", async () => {
    const { bridge } = testBridge();
    vi.mocked(bridge.cancel).mockRejectedValueOnce(new Error("Cleanup failed"));
    const { result } = await ready(bridge);
    await act(() => result.current.program());
    await act(() => result.current.resolve(false));
    expect(result.current.confirmation).not.toBeNull();
    expect(result.current.locked).toBe(true);
    await act(() => result.current.resolve(false));
    expect(result.current.locked).toBe(false);
  });
  it("blocks overlapping commands synchronously and clears old connection on refresh failure", async () => {
    const { bridge } = testBridge();
    const { result } = await ready(bridge);
    let rejectOperation!: (error: unknown) => void;
    vi.mocked(bridge.programmer).mockImplementationOnce(
      () =>
        new Promise<ProgrammerResult>((_resolve, reject) => {
          rejectOperation = reject;
        }),
    );
    let running!: Promise<void>;
    act(() => {
      running = result.current.connect();
      void result.current.connect();
    });
    expect(result.current.connected).toBe(false);
    expect(result.current.readable).toBe(false);
    await act(async () => {
      rejectOperation(new Error("No T76 connected"));
      await running;
    });
    expect(result.current.connected).toBe(false);
    expect(result.current.writable).toBe(false);
    expect(result.current.busy).toBe(false);
  });
});
describe("catalog completeness and file-buffer safety", () => {
  it("rejects an unreadable firmware selection before changing the programming source", async () => {
    const { bridge } = testBridge();
    vi.mocked(bridge.inspectFile).mockRejectedValueOnce(
      new Error("The firmware file is not readable."),
    );
    const { result } = await mounted(bridge);
    await act(() => result.current.chooseFirmware());
    expect(result.current.firmware).toBe("");
    expect(result.current.status).toContain("not readable");
    expect(bridge.prepare).not.toHaveBeenCalled();
  });
  it("loads the count and exactly that many names before filtering locally", async () => {
    const { bridge } = testBridge();
    const { result } = await mounted(bridge);
    act(() => result.current.setQuery("MX25"));
    await act(() => result.current.search());
    expect(bridge.programmer).toHaveBeenNthCalledWith(1, {
      operation: "search",
      query: "",
      limit: 0,
      database: "trusted-db",
    });
    expect(bridge.programmer).toHaveBeenNthCalledWith(2, {
      operation: "search",
      query: "",
      limit: 2,
      database: "trusted-db",
    });
    expect(result.current.otherHits).toEqual([details.name]);
    act(() => result.current.setQuery("OTHER"));
    expect(result.current.otherHits).toEqual(["OTHER@DIP8"]);
    expect(bridge.programmer).toHaveBeenCalledTimes(2);
  });
  it("rejects a truncated catalog rather than presenting partial search results", async () => {
    const { bridge } = testBridge();
    vi.mocked(bridge.programmer)
      .mockResolvedValueOnce({ n: 3 })
      .mockResolvedValueOnce({ n: 3, hits: [details.name], more: true });
    const { result } = await mounted(bridge);
    await act(() => result.current.search(true));
    expect(result.current.catalog).toBeNull();
    expect(result.current.status).toMatch(/database changed/);
  });
  it("keeps firmware selection distinct from buffer data and confirms unsaved replacement", async () => {
    const { bridge } = testBridge();
    const { result } = await ready(bridge);
    vi.mocked(bridge.buffer).mockResolvedValueOnce({
      ...emptyBuffer,
      size: 256,
      bytes: [1, 2],
      source: "/dump.bin",
      dirty: true,
    });
    await act(() => result.current.openBuffer());
    expect(result.current.firmware).toBe("/firmware/source.bin");
    expect(result.current.tab).toBe("hex");
    const opens = vi.mocked(bridge.open).mock.calls.length;
    await act(() => result.current.openBuffer());
    expect(result.current.confirmation?.title).toContain("unsaved changes");
    expect(bridge.open).toHaveBeenCalledTimes(opens);
    await act(() => result.current.resolve(false));
    expect(result.current.buffer.dirty).toBe(true);
    expect(bridge.buffer).toHaveBeenCalledTimes(1);
  });
  it("clears chip provenance when a separate file replaces a chip dump", async () => {
    const { bridge } = testBridge();
    const { result } = await mounted(bridge);
    vi.mocked(bridge.buffer).mockResolvedValueOnce({
      ...emptyBuffer,
      size: 256,
      bytes: [1],
      source: "/chip.bin",
      originChip: details.name,
    });
    await act(() => result.current.openBuffer());
    expect(result.current.buffer.originChip).toBe(details.name);
    await act(() => result.current.openBuffer());
    expect(result.current.buffer.originChip).toBeUndefined();
  });
  it("preserves the visible page when metadata-only save replies have no bytes", async () => {
    const { bridge } = testBridge();
    const { result } = await mounted(bridge);
    await act(() => result.current.openBuffer());
    const bytes = result.current.buffer.bytes;
    await act(() => result.current.saveBuffer());
    expect(result.current.buffer.bytes).toEqual(bytes);
    expect(result.current.buffer.dirty).toBe(false);
  });
  it("requires an explicit discard action before allowing native close", async () => {
    const { bridge, close } = testBridge();
    const { result } = await mounted(bridge);
    act(() => close());
    expect(result.current.confirmation?.title).toContain("unsaved changes");
    await act(() => result.current.resolve(false));
    expect(bridge.allowClose).not.toHaveBeenCalled();
    act(() => close());
    await act(() => result.current.resolve(true));
    expect(bridge.allowClose).toHaveBeenCalledTimes(1);
  });
});
