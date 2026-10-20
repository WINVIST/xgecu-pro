import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  basename,
  canRead,
  canWrite,
  chipDetails,
  errorMessage,
  hex,
  parseHex,
  usbSummary,
} from "./policy";
import {
  emptyBuffer,
  type BufferReply,
  type BufferRequest,
  type ChipDetails,
  type DesktopBridge,
  type DiagnosticReport,
  type PreparedProgram,
  type ProgrammerRequest,
  type Settings,
} from "./types";

export interface Confirmation {
  title: string;
  message: string;
  action: string;
  destructive?: boolean;
  accept(): void | Promise<void>;
  cancel?(): void | Promise<void>;
}
const defaultSettings: Settings = {
  databasePath: "",
  favorites: [],
  theme: "system",
};
export function useApp(bridge: DesktopBridge) {
  const [settings, setSettings] = useState(defaultSettings);
  const [tab, setTab] = useState("program");
  const [connected, setConnected] = useState(false);
  const [deviceStatus, setDeviceStatus] = useState("Programmer not checked");
  const [status, setStatus] = useState(
    "Connect the T76 with the supplied USB cable, then click Connect / Refresh.",
  );
  const [busy, setBusy] = useState(false);
  const [hardware, setHardware] = useState(false);
  const [stage, setStage] = useState("");
  const [progress, setProgress] = useState<number | null>(null);
  const [log, setLog] = useState<string[]>([]);
  const [query, setQuery] = useState("");
  const [catalog, setCatalog] = useState<string[] | null>(null);
  const [detected, setDetected] = useState<string[]>([]);
  const [searched, setSearched] = useState(false);
  const [chip, setChip] = useState("");
  const [details, setDetails] = useState<ChipDetails | null>(null);
  const [setup, setSetup] = useState("");
  const [firmware, setFirmware] = useState("");
  const [firmwareBytes, setFirmwareBytes] = useState<number | null>(null);
  const [prepared, setPrepared] = useState<PreparedProgram | null>(null);
  const [buffer, setBuffer] = useState<BufferReply>(emptyBuffer);
  const [confirmation, setConfirmation] = useState<Confirmation | null>(null);
  const [usbOpen, setUsbOpen] = useState(false);
  const [usbReport, setUsbReport] = useState("");
  const [usbData, setUsbData] = useState<DiagnosticReport | null>(null);
  const [usbConnection, setUsbConnection] = useState("unknown");
  const [usbNotes, setUsbNotes] = useState("");
  const [usbSleep, setUsbSleep] = useState(false);
  const operationLock = useRef(false);
  const startupConnectionChecked = useRef(false);
  const pending = useRef<PreparedProgram | null>(null);
  const modal = useRef<Confirmation | null>(null);
  const live = useRef({ busy, buffer });
  live.current = { busy, buffer };
  modal.current = confirmation;
  const lastSearch = useRef<{ query: string; offset: number } | null>(null);
  const append = useCallback(
    (text: string) =>
      setLog((previous) => [
        ...previous.slice(-4999),
        `[${new Date().toLocaleTimeString("en-GB")}] ${text}`,
      ]),
    [],
  );
  const message = useCallback(
    (text: string) => {
      setStatus(text);
      append(text);
    },
    [append],
  );
  const fail = useCallback(
    (error: unknown) => message(`Error: ${errorMessage(error)}`),
    [message],
  );
  const run = useCallback(
    async <T>(
      label: string,
      action: () => Promise<T>,
      isHardware = false,
    ): Promise<T | undefined> => {
      if (operationLock.current || pending.current) return;
      operationLock.current = true;
      setBusy(true);
      setHardware(isHardware);
      setStage(label);
      setProgress(null);
      setStatus(`${label}…`);
      append(`Started ${label}.`);
      try {
        const result = await action();
        append(`Finished ${label}.`);
        return result;
      } catch (error) {
        fail(error);
        return;
      } finally {
        operationLock.current = false;
        setBusy(false);
        setHardware(false);
        setStage("");
        setProgress(null);
      }
    },
    [append, fail],
  );
  const mergeBuffer = useCallback(
    (reply: BufferReply, replace = false) =>
      setBuffer((previous) =>
        replace
          ? reply
          : {
              ...reply,
              bytes:
                reply.bytes.length || !reply.size
                  ? reply.bytes
                  : previous.bytes,
              offset: reply.bytes.length ? reply.offset : previous.offset,
              source: reply.source ?? previous.source,
              originChip: reply.originChip ?? previous.originChip,
            },
      ),
    [],
  );
  const bufferRun = useCallback(
    (request: BufferRequest, label: string) =>
      run(label, async () => {
        let reply = await bridge.buffer(request);
        if (reply.bytes.length && reply.offset % 256 !== 0) {
          // Mutations return bytes at their affected address. Keep the visible
          // editor on 256-byte page boundaries, including after Undo and Redo.
          reply = await bridge.buffer({
            operation: "page",
            offset: Math.floor(reply.offset / 256) * 256,
            count: 256,
          });
        }
        mergeBuffer(reply, request.operation === "open");
        setStatus(`${label} completed.`);
        return reply;
      }),
    [bridge, mergeBuffer, run],
  );
  const programmer = useCallback(
    (request: ProgrammerRequest, label: string, isHardware = true) =>
      run(
        label,
        () =>
          bridge.programmer({ ...request, database: settings.databasePath }),
        isHardware,
      ),
    [bridge, run, settings.databasePath],
  );
  const updateSettings = useCallback(
    async (change: Partial<Settings>) => {
      if (operationLock.current || pending.current || modal.current) return;
      try {
        const next = await bridge.saveSettings({ ...settings, ...change });
        setSettings(next);
        return next;
      } catch (e) {
        fail(e);
        return;
      }
    },
    [settings, bridge, fail],
  );
  useEffect(() => {
    let disposed = false;
    let unsubscribe: (() => void) | undefined;
    bridge
      .settings()
      .then((s) => {
        if (!disposed) setSettings(s);
      })
      .catch(fail);
    bridge
      .subscribe(
        (event) => {
          if (event.stage) {
            setStage(event.stage);
            setProgress(null);
            append(`Stage: ${event.stage}.`);
          }
          if (event.progress && event.progress.total > 0)
            setProgress(
              Math.min(
                1,
                Math.max(0, event.progress.done / event.progress.total),
              ),
            );
          if (event.note) append(`Note: ${event.note}`);
          if (event.warn)
            append(
              `Warning: ${typeof event.warn === "string" ? event.warn : JSON.stringify(event.warn)}`,
            );
        },
        () => {
          if (operationLock.current || pending.current || modal.current) return;
          setConfirmation({
            title: "The Hex Editor has unsaved changes",
            message:
              "Quitting will discard them. Choose Cancel, then Save As to keep your edits.",
            action: "Quit and Discard",
            destructive: true,
            accept: () => bridge.allowClose().catch(fail),
          });
        },
      )
      .then((off) => {
        if (disposed) off();
        else unsubscribe = off;
      })
      .catch(fail);
    const prevent = (event: BeforeUnloadEvent) => {
      if (live.current.busy || live.current.buffer.dirty || pending.current) {
        event.preventDefault();
        event.returnValue = "";
      }
    };
    window.addEventListener("beforeunload", prevent);
    return () => {
      disposed = true;
      unsubscribe?.();
      window.removeEventListener("beforeunload", prevent);
    };
  }, [bridge, fail, append]);
  useEffect(() => {
    if (!import.meta.env.DEV || !bridge.preview) return;
    const fixture =
      new URLSearchParams(location.search).get("preview") || "start";
    if (fixture === "start") return;
    let disposed = false;
    const showFixture = async () => {
      const result = await bridge.programmer({
        operation: "describe",
        chip: "MX25L51245G@SOIC16",
      });
      if (disposed) return;
      setConnected(true);
      setDeviceStatus("T76 · firmware 00.1.07 · USB hs");
      setChip("MX25L51245G@SOIC16");
      setDetails(chipDetails(result));
      setDetected(["MX25L51245G@SOIC16", "MX25L51245G@WSON8"]);
      setSearched(true);
      setQuery("MX25L512");
      setFirmware("C:\\Firmware\\router-firmware.bin");
      setFirmwareBytes(67108864);
      setStatus("Firmware selected: router-firmware.bin.");
      if (fixture.includes("hex")) {
        const data = await bridge.buffer({
          operation: "open",
          file: "C:\\Firmware\\router-backup.bin",
        });
        if (!disposed) {
          setBuffer(data);
          setTab("hex");
          setStatus("Buffer modified. Save it before programming.");
        }
      }
      if (fixture.includes("error")) {
        setConnected(false);
        setStatus(
          "Error: No T76 connected. Check the USB cable and click Connect / Refresh.",
        );
      }
      if (fixture.includes("usb")) setUsbOpen(true);
    };
    void showFixture().catch(fail);
    return () => {
      disposed = true;
    };
  }, [bridge, fail]);
  const readable = canRead(chip, details, connected);
  const writable = canWrite(chip, details, connected);
  const locked = busy || prepared !== null || confirmation !== null;
  const filtered = useMemo(() => {
    const search = query.trim().toLocaleLowerCase("en-US");
    return (catalog || detected).filter(
      (name) => !catalog || name.toLocaleLowerCase("en-US").includes(search),
    );
  }, [catalog, detected, query]);
  const favoriteSet = useMemo(
    () => new Set(settings.favorites),
    [settings.favorites],
  );
  const favoriteHits = useMemo(
    () =>
      !searched && !query.trim()
        ? settings.favorites
        : filtered.filter((name) => favoriteSet.has(name)),
    [searched, query, settings.favorites, filtered, favoriteSet],
  );
  const otherHits = useMemo(
    () => filtered.filter((name) => !favoriteSet.has(name)),
    [filtered, favoriteSet],
  );
  const connect = useCallback(async () => {
    if (operationLock.current || pending.current || modal.current) return;
    setConnected(false);
    setSetup("");
    setDeviceStatus("Programmer not checked");
    const r = await programmer({ operation: "connect" }, "Checking programmer");
    if (r) {
      setConnected(r.model === "T76");
      setDeviceStatus(
        `${r.model || "Unknown model"} · firmware ${r.fw || "?"} · USB ${r.link || "?"}`,
      );
      message(
        r.model === "T76"
          ? "T76 connected. Select a chip."
          : "This version of the app supports only the T76.",
      );
    }
  }, [programmer, message]);
  useEffect(() => {
    if (
      startupConnectionChecked.current ||
      bridge.preview ||
      navigator.platform !== "Win32"
    )
      return;
    if (operationLock.current || pending.current || modal.current) return;
    startupConnectionChecked.current = true;
    // The native Windows info request checks the USB driver binding. It does
    // not replace a driver or perform a chip operation.
    void connect();
  }, [bridge.preview, connect]);
  const selectChip = useCallback(
    async (name: string) => {
      if (operationLock.current || pending.current || modal.current) return;
      setChip(name);
      setDetails(null);
      setSetup("");
      await run("Loading chip details", async () => {
        const r = await bridge.programmer({
          operation: "describe",
          chip: name,
          database: settings.databasePath,
        });
        setDetails(chipDetails(r));
        message("Chip details loaded from the database.");
      });
    },
    [bridge, settings.databasePath, run, message],
  );
  const search = useCallback(
    async (browse = false) => {
      if (locked) return;
      if (browse) setQuery("");
      if (catalog) {
        setSearched(true);
        message("Catalog filtered by chip name or package.");
        return;
      }
      await run("Loading chip catalog", async () => {
        const count = await bridge.programmer({
          operation: "search",
          query: "",
          limit: 0,
          database: settings.databasePath,
        });
        if (
          !Number.isSafeInteger(count.n) ||
          count.n! < 0 ||
          count.n! > 1000000
        )
          throw new Error("The database returned an invalid catalog count.");
        const r = await bridge.programmer({
          operation: "search",
          query: "",
          limit: count.n,
          database: settings.databasePath,
        });
        if (
          !Array.isArray(r.hits) ||
          r.hits.length !== count.n ||
          r.n !== count.n ||
          r.more !== false ||
          !r.hits.every((n) => typeof n === "string")
        )
          throw new Error(
            "The database changed while loading its catalog. Try browsing again.",
          );
        setCatalog([...new Set(r.hits)].sort());
        setSearched(true);
        message(
          `Catalog loaded: ${r.hits.length.toLocaleString("en-US")} entries. Filter by chip name or package.`,
        );
      });
    },
    [locked, catalog, run, bridge, settings.databasePath, message],
  );
  const autodetect = async () => {
    if (locked || !connected) return;
    setChip("");
    setDetails(null);
    setSetup("");
    setQuery("");
    setCatalog(null);
    setDetected([]);
    const r = await programmer(
      { operation: "autodetect" },
      "Auto detecting SOIC16",
    );
    if (!r) return;
    if (!/^[0-9a-f]{6}$/i.test(r.id || "")) {
      fail(new Error("The programmer returned an invalid JEDEC ID."));
      return;
    }
    const names = Array.isArray(r.matches) ? r.matches : [];
    setDetected(names);
    setSearched(true);
    if (names.length === 1) await selectChip(names[0]);
    message(
      `Detected JEDEC ID 0x${r.id!.toUpperCase()}. ${names.length ? `${r.n || names.length} possible SOIC16 entries. Confirm the exact chip marking and adapter placement.` : "No SOIC16 database entry matches it. Check the chip and adapter placement."}`,
    );
  };
  const chooseFirmware = useCallback(async () => {
    if (operationLock.current || pending.current || modal.current) return;
    try {
      const path = await bridge.open("Choose Firmware");
      if (path) {
        const metadata = await bridge.inspectFile(path);
        setFirmware(path);
        setFirmwareBytes(metadata.bytes);
        setTab("program");
        message(
          `Firmware selected: ${basename(path)}. Select the exact chip, then choose Program and Verify.`,
        );
      }
    } catch (e) {
      fail(e);
    }
  }, [bridge, message, fail]);
  const program = async () => {
    if (locked || !writable || !firmware) return;
    const snapshot = await run(
      "Preparing firmware and checking preflight",
      () => bridge.prepare(chip, firmware, settings.databasePath),
      true,
    );
    if (!snapshot) return;
    pending.current = snapshot;
    setPrepared(snapshot);
    const cancel = async () => {
      await bridge.cancel(snapshot.token);
      pending.current = null;
      setPrepared(null);
      message("Programming cancelled. The chip was not changed.");
    };
    setConfirmation({
      title: `Program ${snapshot.chip}?`,
      message: `Firmware: ${basename(snapshot.file)}\n\nPreflight passed. This will change the chip contents; erasable chips are erased before programming. Short images are padded to the chip capacity with the erased byte. Save the original dump first.`,
      action: "Program and Verify",
      destructive: true,
      cancel,
      accept: async () => {
        pending.current = null;
        setPrepared(null);
        await run(
          "Programming and verifying",
          async () => {
            await bridge.commit(snapshot.token);
            message(
              "Programming completed and verified by a readback. The Hex buffer was not changed; use Read to view the chip.",
            );
          },
          true,
        );
      },
    });
  };
  const discardThen = (action: () => void | Promise<void>) => {
    if (!buffer.dirty) {
      void action();
      return;
    }
    setConfirmation({
      title: "The buffer has unsaved changes",
      message: "Loading another dump will discard those changes.",
      action: "Discard Changes",
      destructive: true,
      accept: action,
    });
  };
  const openBuffer = useCallback(async () => {
    if (operationLock.current || pending.current || modal.current) return;
    const action = async () => {
      try {
        const path = await bridge.open("Open File in Hex Editor");
        if (path) {
          const r = await bufferRun(
            { operation: "open", file: path },
            "Loading image and computing checksum",
          );
          if (r) {
            setTab("hex");
            lastSearch.current = null;
            message(
              `Image loaded: ${basename(path)}, ${r.size.toLocaleString("en-US")} bytes.`,
            );
          }
        }
      } catch (e) {
        fail(e);
      }
    };
    if (buffer.dirty)
      setConfirmation({
        title: "The buffer has unsaved changes",
        message: "Loading another dump will discard those changes.",
        action: "Discard Changes",
        destructive: true,
        accept: action,
      });
    else await action();
  }, [bridge, buffer.dirty, bufferRun, message, fail]);
  const saveBuffer = useCallback(async () => {
    if (
      operationLock.current ||
      pending.current ||
      modal.current ||
      !buffer.size
    )
      return;
    try {
      const path = await bridge.save(
        "Save Hex Buffer As",
        basename(buffer.source || "buffer.bin"),
      );
      if (path) {
        const r = await bufferRun(
          { operation: "save", file: path },
          "Saving buffer",
        );
        if (r) message(`Buffer saved: ${basename(path)}.`);
      }
    } catch (e) {
      fail(e);
    }
  }, [bridge, bufferRun, buffer.size, buffer.source, message, fail]);
  const read = () => {
    if (locked || !readable) return;
    discardThen(async () => {
      try {
        const path = await bridge.save(
          "Read and Save",
          `${chip.replace(/@/g, "_")}.bin`,
        );
        if (!path) return;
        const r = await programmer(
          { operation: "read", chip, file: path },
          "Reading chip twice",
        );
        if (r) {
          const b = await bufferRun(
            { operation: "open", file: path, originChip: chip },
            "Loading chip dump",
          );
          if (b) setTab("hex");
          message(
            r.stable === true
              ? "Dump saved and confirmed by a second read."
              : "The dump was saved, but the second read differed. Check the chip contact and read it again.",
          );
        }
      } catch (e) {
        fail(e);
      }
    });
  };
  const verify = async () => {
    if (locked || !readable) return;
    try {
      const file = await bridge.open("Verify Against File");
      if (file) {
        const r = await programmer(
          { operation: "verify", chip, file },
          "Verifying against file",
        );
        if (r)
          message(
            r.stable !== true
              ? "Repeated reads differ; verification is unreliable. Check the chip contact."
              : r.matches === true
                ? "Chip contents match the file."
                : `Chip contents differ from the file${typeof r.first_mismatch === "number" ? ` at address 0x${hex(r.first_mismatch, 6)}` : ""}.`,
          );
      }
    } catch (e) {
      fail(e);
    }
  };
  const blank = async () => {
    if (locked || !readable) return;
    const r = await programmer(
      { operation: "blank", chip },
      "Checking erased contents",
    );
    if (r)
      message(
        r.blank === true
          ? "The chip is blank: every byte has the erased value."
          : "The chip is not blank. Save a dump before erasing it.",
      );
  };
  const erase = () => {
    if (locked || !writable || !details?.can_erase) return;
    setConfirmation({
      title: `Erase ${chip}?`,
      message: "All data on the chip will be erased. Save a dump first.",
      action: "Erase",
      destructive: true,
      accept: async () => {
        const r = await programmer(
          { operation: "erase", chip },
          "Erasing chip",
        );
        if (r) message("Erase completed.");
      },
    });
  };
  const check = async () => {
    if (locked || !readable) return;
    setSetup("");
    const r = await programmer(
      { operation: "check", chip },
      "Checking chip setup",
    );
    if (r) {
      const text = `Last setup check: ${r.chip_id_checked ? "Chip ID matches the selected entry." : "This entry has no electronic ID; identity must be checked from the marking."} ${r.pins_checked && Array.isArray(r.open_pins) ? (r.open_pins.length ? `Open contacts: ${r.open_pins.join(", ")}. Check seating and adapter contacts.` : "Socket contact test passed.") : "Contact self-test is unavailable on this programmer. Check the chip and adapter seating."}`;
      setSetup(text);
      message(text);
    }
  };
  const database = async (local: boolean) => {
    if (locked) return;
    try {
      const path = local
        ? await bridge.open("Choose Local Database", true)
        : "";
      if (path === null) return;
      if (!(await updateSettings({ databasePath: path }))) return;
      setCatalog(null);
      setDetected([]);
      setChip("");
      setDetails(null);
      setSetup("");
      setSearched(false);
      message(
        local
          ? "Local database selected. Search for a chip again."
          : "Automatic database selected. Search for a chip again.",
      );
    } catch (e) {
      fail(e);
    }
  };
  const compare = async () => {
    if (locked || !buffer.size) return;
    try {
      const file = await bridge.open("Compare Buffer with File");
      if (file) {
        const r = await bufferRun(
          { operation: "compare", file },
          "Comparing buffer with file",
        );
        if (r)
          message(
            r.matches
              ? `The buffer matches ${basename(file)} byte for byte.`
              : `Difference from ${basename(file)} at address 0x${hex(r.firstMismatch || 0)} (sizes: ${buffer.size} and ${r.otherBytes} bytes).`,
          );
      }
    } catch (e) {
      fail(e);
    }
  };
  const page = async (offset: number) => {
    if (locked || !buffer.size) return;
    if (!Number.isSafeInteger(offset) || offset < 0 || offset >= buffer.size) {
      fail(new Error("The address is outside the buffer."));
      return;
    }
    lastSearch.current = null;
    await bufferRun(
      { operation: "page", offset: Math.floor(offset / 256) * 256, count: 256 },
      "Loading hex page",
    );
  };
  const find = async (query: string, ascii: boolean, address: string) => {
    if (locked || !buffer.size) return;
    try {
      const key = `${ascii}:${query}`;
      const start =
        lastSearch.current?.query === key
          ? lastSearch.current.offset + 1
          : parseHex(address);
      const r = await bufferRun(
        { operation: ascii ? "find_ascii" : "find_hex", query, offset: start },
        "Searching buffer",
      );
      if (r) {
        if (r.foundOffset === undefined) {
          message("Byte sequence not found.");
          return;
        }
        lastSearch.current = { query: key, offset: r.foundOffset };
        await bufferRun(
          {
            operation: "page",
            offset: Math.floor(r.foundOffset / 256) * 256,
            count: 256,
          },
          "Loading search result",
        );
        message(`Found at address 0x${hex(r.foundOffset)}.`);
      }
    } catch (e) {
      fail(e);
    }
  };
  const edit = async (request: BufferRequest) => {
    if (locked || !buffer.size) return;
    const execute = async () => {
      const r = await bufferRun(request, "Updating hex buffer");
      if (r) message("Buffer modified. Save it before programming.");
    };
    if (request.operation === "fill")
      setConfirmation({
        title: "Fill the buffer range?",
        message: `Addresses 0x${hex(request.start || 0)}…0x${hex(request.end || 0)} will be set to 0x${hex(request.value || 0, 2)}. This does not program the chip.`,
        action: "Fill",
        accept: execute,
      });
    else await execute();
  };
  const exportBlock = async (start: number, end: number) => {
    if (locked || !buffer.size) return;
    try {
      const file = await bridge.save(
        "Export Buffer Block",
        `block_${hex(start)}_${hex(end)}.bin`,
      );
      if (file) {
        const r = await bufferRun(
          { operation: "export", file, start, end },
          "Exporting buffer block",
        );
        if (r)
          message(`Exported ${end - start + 1} bytes to ${basename(file)}.`);
      }
    } catch (e) {
      fail(e);
    }
  };
  const diagnose = async () => {
    if (locked) return;
    setConnected(false);
    setDeviceStatus("USB diagnostics; refresh before chip operations");
    setUsbData(null);
    setUsbReport("");
    const result = await run(
      "Testing USB connection",
      async () => {
        try {
          return await bridge.programmer({
            operation: "usb_diagnose",
            disableDeviceU1U2: usbSleep,
          });
        } catch (e) {
          return {
            ok: false,
            op: "usb-diagnose",
            report: { passed: false, error: errorMessage(e) },
          };
        }
      },
      true,
    );
    if (result) {
      const report = result.report || {
        passed: false,
        error: "The USB helper returned no diagnostic report.",
      };
      setUsbData(report);
      setUsbReport(
        JSON.stringify(
          {
            ...result,
            schema_version: 2,
            connection: {
              kind: usbConnection,
              description: usbNotes.trim().slice(0, 240),
              source: "user-provided",
            },
            platform: navigator.platform,
            app_version: "1.2.0-beta.1",
            date: new Date().toISOString(),
          },
          null,
          2,
        ),
      );
      message(usbSummary(report).title);
    }
  };
  const saveReport = async () => {
    if (locked || !usbReport) return;
    try {
      const path = await bridge.save(
        "Save USB Report",
        `T76-USB-${usbSleep ? "device-u1-u2-disabled" : "baseline"}.json`,
      );
      if (path) {
        await bridge.saveText(path, usbReport);
        message(`USB report saved: ${basename(path)}.`);
      }
    } catch (e) {
      fail(e);
    }
  };
  const copyReport = async () => {
    try {
      await navigator.clipboard.writeText(usbReport);
      message("USB report copied.");
    } catch (e) {
      fail(e);
    }
  };
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (
        !e.ctrlKey ||
        e.altKey ||
        e.metaKey ||
        operationLock.current ||
        pending.current ||
        modal.current
      )
        return;
      if (e.key.toLowerCase() === "o") {
        e.preventDefault();
        void (e.shiftKey ? openBuffer() : chooseFirmware());
      } else if (e.key.toLowerCase() === "s" && e.shiftKey) {
        e.preventDefault();
        void saveBuffer();
      } else if (e.key.toLowerCase() === "r") {
        e.preventDefault();
        void connect();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [openBuffer, chooseFirmware, saveBuffer, connect]);
  const resolve = async (accept: boolean) => {
    const c = modal.current;
    if (!c) return;
    setConfirmation(null);
    modal.current = null;
    try {
      await (accept ? c.accept() : c.cancel?.());
    } catch (e) {
      fail(e);
      if (pending.current) setConfirmation(c);
    }
  };
  return {
    bridge,
    settings,
    updateSettings,
    tab,
    setTab,
    connected,
    deviceStatus,
    status,
    busy,
    hardware,
    stage,
    progress,
    log,
    query,
    setQuery,
    catalog,
    searched,
    favoriteHits,
    otherHits,
    chip,
    details,
    setup,
    firmware,
    firmwareBytes,
    prepared,
    buffer,
    confirmation,
    locked,
    readable,
    writable,
    usbOpen,
    setUsbOpen,
    usbReport,
    usbData,
    usbConnection,
    setUsbConnection,
    usbNotes,
    setUsbNotes,
    usbSleep,
    setUsbSleep,
    connect,
    selectChip,
    search,
    autodetect,
    chooseFirmware,
    program,
    openBuffer,
    saveBuffer,
    read,
    verify,
    blank,
    erase,
    check,
    database,
    compare,
    page,
    find,
    edit,
    exportBlock,
    bufferRun,
    fail,
    resolve,
    diagnose,
    saveReport,
    copyReport,
    resetUsb: () => {
      setUsbReport("");
      setUsbData(null);
      setUsbSleep(false);
    },
  };
}
export type AppModel = ReturnType<typeof useApp>;
