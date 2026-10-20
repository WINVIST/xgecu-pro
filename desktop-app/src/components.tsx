import {
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import {
  AlertCircle,
  AlertTriangle,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  Cpu,
  Download,
  File,
  FileText,
  FolderOpen,
  Info,
  List,
  ListChecks,
  LoaderCircle,
  RefreshCw,
  Search,
  Settings,
  ShieldCheck,
  Sparkles,
  Star,
  Stethoscope,
  Upload,
  Usb,
  X,
} from "lucide-react";
import type { AppModel } from "./useApp";
import { basename, byteCount, hex, parseHex, usbSummary } from "./policy";

export function Disclosure({
  title,
  children,
  initial = false,
  disabled = false,
}: {
  title: string;
  children: ReactNode;
  initial?: boolean;
  disabled?: boolean;
}) {
  return (
    <details
      className="disclosure"
      open={initial || undefined}
      onToggle={(event) => {
        if (disabled) (event.currentTarget as HTMLDetailsElement).open = false;
      }}
    >
      <summary aria-disabled={disabled}>
        <ChevronRight size={13} />
        {title}
      </summary>
      <div className="disclosure-content">{children}</div>
    </details>
  );
}
export function Modal({
  title,
  children,
  footer,
  onCancel,
  className = "",
  preventEnter = false,
}: {
  title: string;
  children: ReactNode;
  footer: ReactNode;
  onCancel?: () => void;
  className?: string;
  preventEnter?: boolean;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  const returnFocus = useRef<HTMLElement | null>(null);
  useLayoutEffect(() => {
    returnFocus.current = document.activeElement as HTMLElement;
    dialog.current?.showModal();
    dialog.current?.querySelector<HTMLElement>("[data-cancel]")?.focus();
    return () => {
      dialog.current?.close();
      const target = returnFocus.current?.matches(":disabled")
        ? document.querySelector<HTMLElement>(
            '[role="tab"][aria-selected="true"]',
          )
        : returnFocus.current;
      target?.focus();
    };
  }, []);
  return (
    <dialog
      ref={dialog}
      className={`modal ${className}`}
      aria-labelledby={titleId}
      onCancel={(e) => {
        e.preventDefault();
        onCancel?.();
      }}
      onKeyDown={(e) => {
        if (preventEnter && e.key === "Enter") {
          e.preventDefault();
          e.stopPropagation();
          onCancel?.();
        }
      }}
    >
      <div className="modal-heading">
        <h2 id={titleId}>{title}</h2>
        {onCancel && (
          <button
            className="icon-button"
            aria-label="Close dialog"
            onClick={onCancel}
          >
            <X size={17} />
          </button>
        )}
      </div>
      <div className="modal-content">{children}</div>
      <div className="modal-footer">{footer}</div>
    </dialog>
  );
}
type BrowserRow =
  | { label: string; section: true }
  | { name: string; section?: false };
function ChipRows({ model }: { model: AppModel }) {
  const { favoriteHits, otherHits, chip, settings } = model;
  const rows: BrowserRow[] = useMemo(
    () => [
      ...(favoriteHits.length
        ? [
            { label: "Favorites", section: true as const },
            ...favoriteHits.map((name) => ({ name })),
          ]
        : []),
      ...(otherHits.length
        ? [
            {
              label: model.catalog ? "Catalog" : "Results",
              section: true as const,
            },
            ...otherHits.map((name) => ({ name })),
          ]
        : []),
    ],
    [favoriteHits, otherHits, model.catalog],
  );
  const scroller = useRef<HTMLDivElement>(null);
  const [scroll, setScroll] = useState(0);
  const [height, setHeight] = useState(250);
  useEffect(() => {
    if (!scroller.current) return;
    const observer = new ResizeObserver((e) =>
      setHeight(e[0].contentRect.height),
    );
    observer.observe(scroller.current);
    return () => observer.disconnect();
  }, []);
  useEffect(() => {
    scroller.current?.scrollTo(0, 0);
    setScroll(0);
  }, [model.query, model.catalog]);
  const rowHeight = 52;
  const first = Math.max(0, Math.floor(scroll / rowHeight) - 3);
  const last = Math.min(
    rows.length,
    Math.ceil((scroll + height) / rowHeight) + 3,
  );
  return (
    <div
      className="chip-list"
      ref={scroller}
      onScroll={(e) => setScroll(e.currentTarget.scrollTop)}
      role="list"
      aria-label="Chip database entries"
      aria-busy={model.busy}
      onKeyDown={(event) => {
        const target = event.target as HTMLElement;
        if (
          model.locked ||
          !target.matches(".chip-select") ||
          !["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)
        )
          return;
        event.preventDefault();
        const direction =
          event.key === "ArrowUp" || event.key === "End" ? -1 : 1;
        const current = rows.findIndex(
          (row) => !row.section && row.name === target.dataset.chip,
        );
        let next =
          event.key === "Home"
            ? 0
            : event.key === "End"
              ? rows.length - 1
              : current + direction;
        while (next >= 0 && next < rows.length && rows[next].section)
          next += direction;
        const row = rows[next];
        if (!row || row.section) return;
        const scrollTop = Math.max(0, next * rowHeight - height / 2);
        if (scroller.current) scroller.current.scrollTop = scrollTop;
        setScroll(scrollTop);
        void model.selectChip(row.name).then(() =>
          requestAnimationFrame(() => {
            scroller.current
              ?.querySelector<HTMLButtonElement>(
                `[data-chip="${CSS.escape(row.name)}"]`,
              )
              ?.focus();
          }),
        );
      }}
    >
      {rows.length ? (
        <div>
          <div aria-hidden="true" style={{ height: first * rowHeight }} />
          {rows.slice(first, last).map((row) =>
            row.section ? (
              <div className="chip-section" key={`section-${row.label}`}>
                {row.label}
              </div>
            ) : (
              <div
                role="listitem"
                key={row.name}
                className={`chip-row ${chip === row.name ? "selected" : ""}`}
              >
                <button
                  className="chip-select"
                  data-chip={row.name}
                  aria-pressed={chip === row.name}
                  disabled={model.locked}
                  title={row.name}
                  onClick={() => void model.selectChip(row.name)}
                >
                  <span>{row.name.split("@")[0]}</span>
                  <small>{row.name.split("@").slice(1).join("@")}</small>
                </button>
                <button
                  className="favorite"
                  disabled={model.locked}
                  aria-label={`${settings.favorites.includes(row.name) ? "Remove from" : "Add to"} favorites: ${row.name}`}
                  aria-pressed={settings.favorites.includes(row.name)}
                  onClick={() =>
                    void model.updateSettings({
                      favorites: settings.favorites.includes(row.name)
                        ? settings.favorites.filter((n) => n !== row.name)
                        : [...settings.favorites, row.name].sort(),
                    })
                  }
                >
                  <Star
                    size={15}
                    fill={
                      settings.favorites.includes(row.name)
                        ? "currentColor"
                        : "none"
                    }
                  />
                </button>
              </div>
            ),
          )}
          <div
            aria-hidden="true"
            style={{ height: (rows.length - last) * rowHeight }}
          />
        </div>
      ) : (
        <div className="sidebar-empty">
          {model.busy ? (
            <LoaderCircle className="spin" size={23} />
          ) : (
            <Cpu size={27} />
          )}
          <strong>
            {model.busy
              ? "Preparing chip lookup…"
              : model.searched
                ? "No matching chips"
                : "Find your chip"}
          </strong>
          <span>
            {model.busy
              ? model.stage
              : model.searched
                ? "Try a shorter part number or check the marking."
                : "Search by part number or use SOIC16 auto detection."}
          </span>
        </div>
      )}
    </div>
  );
}
export function Sidebar({ model }: { model: AppModel }) {
  const [settingsOpen, setSettingsOpen] = useState(false);
  return (
    <aside className="sidebar">
      <h1>Chips</h1>
      <div className="device-section">
        <h3>
          {model.connected ? <CheckCircle2 size={17} /> : <Usb size={17} />}{" "}
          {model.connected ? "T76 connected" : "Connect your programmer"}
        </h3>
        <p className="caption device-status">{model.deviceStatus}</p>
        <button
          disabled={model.locked}
          title="Check the programmer and USB link. Ctrl+R."
          onClick={() => void model.connect()}
        >
          <RefreshCw size={14} />
          Connect / Refresh
        </button>
        <button disabled={model.locked} onClick={() => model.setUsbOpen(true)}>
          <Stethoscope size={14} />
          USB Diagnostics…
        </button>
      </div>
      <hr />
      <div className="chip-search">
        <h3>Select the exact chip</h3>
        <p className="caption">Match the marking printed on the chip.</p>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            void model.search();
          }}
        >
          <input
            aria-label="Search chip database"
            placeholder="Chip name, e.g. MX25L512"
            value={model.query}
            disabled={model.locked}
            onChange={(e) => model.setQuery(e.target.value)}
          />
          <button
            className="icon-button"
            aria-label="Search chips"
            title="Search the full chip database"
            disabled={model.locked || !model.query.trim()}
          >
            <Search size={15} />
          </button>
        </form>
        <button
          disabled={model.locked || !model.connected}
          onClick={() => void model.autodetect()}
        >
          <Sparkles size={14} />
          Auto Detect SOIC16
        </button>
        <button disabled={model.locked} onClick={() => void model.search(true)}>
          <List size={14} />
          Browse All Chips
        </button>
      </div>
      <ChipRows model={model} />
      {model.favoriteHits.length + model.otherHits.length > 0 && (
        <p className="caption result-count">
          {model.catalog
            ? `${(model.favoriteHits.length + model.otherHits.length).toLocaleString("en-US")} of ${model.catalog.length.toLocaleString("en-US")} entries`
            : `${model.favoriteHits.length + model.otherHits.length} results · select to load details`}
        </p>
      )}
      <hr />
      <div className="database">
        <div>
          <strong>Chip database</strong>
          <p title={model.settings.databasePath}>
            {model.settings.databasePath ||
              "automatic (cached after first download)"}
          </p>
        </div>
        <div className="settings-wrap">
          <button
            disabled={model.locked}
            className="icon-button"
            aria-label="Chip database settings"
            aria-expanded={settingsOpen}
            onClick={() => setSettingsOpen(!settingsOpen)}
          >
            <Settings size={16} />
          </button>
          {settingsOpen && (
            <div className="settings-menu">
              <button
                disabled={model.locked}
                onClick={() => {
                  setSettingsOpen(false);
                  void model.database(true);
                }}
              >
                Choose Local Database…
              </button>
              <button
                disabled={model.locked || !model.settings.databasePath}
                onClick={() => {
                  setSettingsOpen(false);
                  void model.database(false);
                }}
              >
                Use Automatic Database
              </button>
              <hr />
              <label>
                Appearance
                <select
                  aria-label="Appearance"
                  value={model.settings.theme}
                  disabled={model.locked}
                  onChange={(e) =>
                    void model.updateSettings({
                      theme: e.target.value as "system" | "light" | "dark",
                    })
                  }
                >
                  <option value="system">System</option>
                  <option value="light">Light</option>
                  <option value="dark">Dark</option>
                </select>
              </label>
              <small>XGecu Pro 1.2.0-beta.1</small>
            </div>
          )}
        </div>
      </div>
    </aside>
  );
}
function Group({
  icon,
  title,
  children,
}: {
  icon: ReactNode;
  title: string;
  children: ReactNode;
}) {
  return (
    <fieldset className="group">
      <legend>
        {icon}
        {title}
      </legend>
      {children}
    </fieldset>
  );
}
export function Program({ model }: { model: AppModel }) {
  const d = model.details;
  const readiness = model.busy
    ? model.stage || "Operation in progress…"
    : !model.connected
      ? "Connect the T76 to enable programming."
      : !model.chip
        ? "Select the exact chip in the sidebar."
        : !d
          ? "Wait for the chip details to load."
          : !model.writable
            ? "Programming needs a database electronic ID and a code region of 1 byte to 2 GiB."
            : !model.firmware
              ? "Choose the firmware file to program."
              : "Ready for preflight. The chip ID and image are checked before confirmation.";
  return (
    <section className="program workspace" aria-label="Program workspace">
      <header className="workspace-heading">
        <h2>Program a chip</h2>
        <p>
          Select the chip, choose your firmware, then program with readback
          verification.
        </p>
      </header>
      <Group icon={<Cpu size={14} />} title="1 · Chip">
        <div className="row align-top">
          <div className="grow">
            <h3 className="selectable">{model.chip || "No chip selected"}</h3>
            <p>
              {d
                ? `${d.package} · ${d.pins} pins · ${byteCount(d.code_bytes)} code region`
                : "Choose the marking and package from the sidebar."}
            </p>
          </div>
          <button
            disabled={model.locked || !model.readable}
            title="Check chip identity and report available contact diagnostics without changing chip contents"
            onClick={() => void model.check()}
          >
            Check Setup
          </button>
        </div>
        {model.setup && (
          <p className="caption inline-note">
            <Info size={13} />
            {model.setup}
          </p>
        )}
        {d && (
          <>
            <Disclosure title="Database details">
              <dl className="chip-details">
                <dt>Electronic ID</dt>
                <dd>{d.chip_id ? `0x${d.chip_id}` : "Not specified"}</dd>
                <dt>Data / extra data</dt>
                <dd>
                  {d.data_bytes.toLocaleString("en-US")} /{" "}
                  {d.data2_bytes.toLocaleString("en-US")} bytes
                </dd>
                <dt>Page / erased value</dt>
                <dd>
                  {d.page_bytes.toLocaleString("en-US")} bytes / 0x
                  {d.blank_value}
                </dd>
                <dt>Electrical erase</dt>
                <dd>{d.can_erase ? "Available" : "Not available"}</dd>
              </dl>
            </Disclosure>
            <p className="caption">
              A database entry does not establish hardware-tested support.
            </p>
          </>
        )}
      </Group>
      <Group icon={<File size={14} />} title="2 · Firmware">
        <div className="row align-top">
          <div className="grow">
            <h3 className="selectable">
              {model.firmware
                ? basename(model.firmware)
                : "No firmware selected"}
            </h3>
            {model.firmware ? (
              <>
                <p>
                  {model.firmwareBytes === null
                    ? "Size checked during preflight"
                    : `${byteCount(model.firmwareBytes)} on disk`}
                </p>
                <p className="caption file-path" title={model.firmware}>
                  {model.firmware}
                </p>
              </>
            ) : (
              <p>Choose a binary (.bin), Intel HEX or S-record file.</p>
            )}
            <p className="caption">
              Programming uses this file. Save HEX editor changes before
              choosing it.
            </p>
          </div>
          <button
            disabled={model.locked}
            title="Choose the source file for programming. Ctrl+O."
            onClick={() => void model.chooseFirmware()}
          >
            <FolderOpen size={14} />
            {model.firmware ? "Change File…" : "Choose Firmware…"}
          </button>
        </div>
      </Group>
      <Group icon={<ShieldCheck size={14} />} title="3 · Program and verify">
        <p>{readiness}</p>
        <div className="program-action row">
          <p className="caption grow inline-note">
            <AlertTriangle size={14} />
            Save the original dump first. Programming changes chip contents.
          </p>
          <button
            className="primary large"
            disabled={model.locked || !model.writable || !model.firmware}
            title={readiness}
            onClick={() => void model.program()}
          >
            <Download size={16} />
            Program and Verify…
          </button>
        </div>
      </Group>
      <Disclosure title="Read, compare or erase the chip">
        <div className="row other-operations">
          <button
            disabled={model.locked || !model.readable}
            onClick={model.read}
          >
            <Upload size={14} />
            Read and Save…
          </button>
          <button
            disabled={model.locked || !model.readable}
            onClick={() => void model.verify()}
          >
            Verify Against File…
          </button>
          <button
            disabled={model.locked || !model.readable}
            onClick={() => void model.blank()}
          >
            Blank Check
          </button>
          <span className="grow" />
          <button
            className="destructive"
            disabled={model.locked || !model.writable || !d?.can_erase}
            onClick={model.erase}
          >
            Erase…
          </button>
        </div>
        <p className="caption">
          Read saves a dump and confirms it with a second read. Erase requires
          confirmation.
        </p>
      </Disclosure>
    </section>
  );
}
function HexField({
  label,
  value,
  set,
  width = 80,
}: {
  label: string;
  value: string;
  set: (value: string) => void;
  width?: number;
}) {
  return (
    <input
      className="hex-field"
      aria-label={label}
      value={value}
      onChange={(e) => set(e.target.value)}
      style={{ width }}
      spellCheck={false}
    />
  );
}
export function HexEditor({ model }: { model: AppModel }) {
  const b = model.buffer;
  const [address, setAddress] = useState("0");
  const [ascii, setAscii] = useState(false);
  const [query, setQuery] = useState("");
  const [byteAddress, setByteAddress] = useState("0");
  const [byteValue, setByteValue] = useState("FF");
  const [fillStart, setFillStart] = useState("0");
  const [fillEnd, setFillEnd] = useState("0");
  const [fillValue, setFillValue] = useState("FF");
  const [blockStart, setBlockStart] = useState("0");
  const [blockEnd, setBlockEnd] = useState("0");
  const [destination, setDestination] = useState("0");
  useEffect(() => setAddress(hex(b.offset)), [b.offset]);
  const checked = (action: () => void | Promise<void>) => {
    try {
      void action();
    } catch (e) {
      model.fail(e);
    }
  };
  const rows = Array.from(
    { length: Math.ceil(b.bytes.length / 16) },
    (_, i) => {
      const bytes = b.bytes.slice(i * 16, i * 16 + 16);
      return `${hex(b.offset + i * 16, 8)}  ${bytes
        .map((n) => hex(n, 2))
        .join(" ")
        .padEnd(
          47,
        )}  ${bytes.map((n) => (n >= 32 && n <= 126 ? String.fromCharCode(n) : ".")).join("")}`;
    },
  ).join("\n");
  return (
    <section className="hex-workspace" aria-label="Hex Editor workspace">
      <div className="hex-controls">
        <div className="row wrap">
          <button
            disabled={model.locked}
            title="Ctrl+Shift+O"
            onClick={() => void model.openBuffer()}
          >
            <FolderOpen size={14} />
            Open File…
          </button>
          <button
            disabled={model.locked || !b.size}
            title="Ctrl+Shift+S"
            onClick={() => void model.saveBuffer()}
          >
            <Download size={14} />
            Save As…
          </button>
          <button
            disabled={model.locked || !b.size}
            onClick={() => void model.compare()}
          >
            Compare with File…
          </button>
          <span className="grow" />
          <span className="caption">
            {b.size
              ? `${byteCount(b.size)}${b.dirty ? " · unsaved" : ""}`
              : "Buffer empty"}
          </span>
        </div>
        {b.originChip && model.chip && b.originChip !== model.chip && (
          <p className="warning caption inline-note">
            <AlertTriangle size={14} />
            This buffer was read from {b.originChip}, not the selected{" "}
            {model.chip}.
          </p>
        )}
        {!!b.size && (
          <Disclosure title="Source and checksum">
            <p className="caption selectable">
              Buffer: {basename(b.source || "Untitled")}
              {b.originChip
                ? ` · read from ${b.originChip}`
                : " · opened from file"}
            </p>
            <p className="caption checksum">SHA-256: {b.sha256}</p>
          </Disclosure>
        )}
        <fieldset disabled={model.locked || !b.size} className="unstyled">
          <div className="row">
            <button
              className="icon-button"
              aria-label="Previous hex page"
              disabled={!b.offset}
              onClick={() => void model.page(Math.max(0, b.offset - 256))}
            >
              <ChevronLeft size={15} />
            </button>
            <button
              className="icon-button"
              aria-label="Next hex page"
              disabled={b.offset + 256 >= b.size}
              onClick={() => void model.page(b.offset + 256)}
            >
              <ChevronRight size={15} />
            </button>
            <label className="caption" htmlFor="hex-address">
              Address 0x
            </label>
            <input
              id="hex-address"
              className="hex-field"
              aria-label="Hexadecimal buffer address"
              value={address}
              onChange={(e) => setAddress(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter")
                  checked(() => model.page(parseHex(address)));
              }}
            />
            <button
              onClick={() => checked(() => model.page(parseHex(address)))}
            >
              Go
            </button>
            <span className="grow" />
            <span className="caption mono">
              0x{hex(b.offset)}–0x
              {hex(Math.max(b.offset, Math.min(b.offset + 256, b.size) - 1))}
            </span>
          </div>
          <form
            className="row search-bytes"
            onSubmit={(e) => {
              e.preventDefault();
              void model.find(query, ascii, address);
            }}
          >
            <div
              className="segmented small"
              role="group"
              aria-label="Search format"
            >
              <button
                type="button"
                aria-pressed={!ascii}
                onClick={() => setAscii(false)}
              >
                HEX
              </button>
              <button
                type="button"
                aria-pressed={ascii}
                onClick={() => setAscii(true)}
              >
                ASCII
              </button>
            </div>
            <input
              className="grow"
              aria-label={ascii ? "Find ASCII text" : "Find hex bytes"}
              placeholder={
                ascii ? "Find printable text" : "Find bytes, e.g. DE AD BE EF"
              }
              value={query}
              onChange={(e) => setQuery(e.target.value)}
            />
            <button>Find Next</button>
          </form>
          <Disclosure title="Edit buffer">
            <div className="edit-tools">
              <div className="row">
                <span>Byte at 0x</span>
                <HexField
                  label="Byte address"
                  value={byteAddress}
                  set={setByteAddress}
                />
                <span>= 0x</span>
                <HexField
                  label="Byte value"
                  value={byteValue}
                  set={setByteValue}
                  width={46}
                />
                <button
                  onClick={() =>
                    checked(() =>
                      model.edit({
                        operation: "edit",
                        offset: parseHex(byteAddress),
                        value: parseHex(byteValue),
                      }),
                    )
                  }
                >
                  Set Byte
                </button>
                <span className="grow" />
                <button
                  disabled={!b.canUndo}
                  onClick={() =>
                    void model.bufferRun(
                      { operation: "undo" },
                      "Undoing buffer edit",
                    )
                  }
                >
                  Undo
                </button>
                <button
                  disabled={!b.canRedo}
                  onClick={() =>
                    void model.bufferRun(
                      { operation: "redo" },
                      "Restoring buffer edit",
                    )
                  }
                >
                  Redo
                </button>
              </div>
              <div className="row">
                <span>Fill 0x</span>
                <HexField
                  label="Fill start address"
                  value={fillStart}
                  set={setFillStart}
                />
                <span>…0x</span>
                <HexField
                  label="Fill end address"
                  value={fillEnd}
                  set={setFillEnd}
                />
                <span>with 0x</span>
                <HexField
                  label="Fill byte"
                  value={fillValue}
                  set={setFillValue}
                  width={46}
                />
                <button
                  onClick={() =>
                    checked(() =>
                      model.edit({
                        operation: "fill",
                        start: parseHex(fillStart),
                        end: parseHex(fillEnd),
                        value: parseHex(fillValue),
                      }),
                    )
                  }
                >
                  Fill Range…
                </button>
              </div>
              <div className="row">
                <span>Block 0x</span>
                <HexField
                  label="Block start address"
                  value={blockStart}
                  set={setBlockStart}
                />
                <span>…0x</span>
                <HexField
                  label="Block end address"
                  value={blockEnd}
                  set={setBlockEnd}
                />
                <span>to 0x</span>
                <HexField
                  label="Block destination address"
                  value={destination}
                  set={setDestination}
                />
                <button
                  onClick={() =>
                    checked(() =>
                      model.edit({
                        operation: "copy",
                        start: parseHex(blockStart),
                        end: parseHex(blockEnd),
                        destination: parseHex(destination),
                      }),
                    )
                  }
                >
                  Copy
                </button>
                <button
                  onClick={() =>
                    checked(() =>
                      model.exportBlock(
                        parseHex(blockStart),
                        parseHex(blockEnd),
                      ),
                    )
                  }
                >
                  Export…
                </button>
              </div>
              <p className="caption">
                All addresses and byte values are hexadecimal. Range endpoints
                are inclusive.
              </p>
            </div>
          </Disclosure>
        </fieldset>
      </div>
      <hr />
      {b.size ? (
        <pre
          className="hex-bytes"
          aria-label="Hexadecimal and ASCII buffer contents"
          tabIndex={0}
        >
          {rows}
        </pre>
      ) : (
        <div className="empty-state">
          <FileText size={37} />
          <h2>No image open</h2>
          <p>
            Open a dump file or read a chip to inspect its bytes.
            <br />
            Firmware selection is separate from this buffer.
          </p>
          <button
            disabled={model.locked}
            onClick={() => void model.openBuffer()}
          >
            Open File…
          </button>
        </div>
      )}
      <p className="caption hex-footer">
        Editing changes the buffer only. Save it, then choose that file under
        Program to flash it.
      </p>
    </section>
  );
}
export function Activity({ model }: { model: AppModel }) {
  return model.log.length ? (
    <pre className="activity-log" aria-label="Activity log" tabIndex={0}>
      {model.log.join("\n")}
    </pre>
  ) : (
    <section className="empty-state">
      <ListChecks size={37} />
      <h2>No operations yet</h2>
      <p>Connection checks, operation stages and results appear here.</p>
    </section>
  );
}
export function OperationStatus({ model }: { model: AppModel }) {
  return (
    <footer
      className="operation-status"
      role="status"
      aria-live="polite"
      aria-atomic="true"
    >
      <div
        className={`row align-top ${model.status.startsWith("Error:") ? "error" : ""}`}
      >
        {model.status.startsWith("Error:") ? (
          <AlertCircle size={16} />
        ) : (
          <Info size={16} />
        )}
        <span>{model.status}</span>
      </div>
      {model.busy && (
        <div className="progress-status">
          <div className="row">
            <strong>{model.stage || "Preparing operation…"}</strong>
            <span className="grow" />
            {model.progress !== null && (
              <span>{Math.floor(model.progress * 100)}% of this stage</span>
            )}
          </div>
          <progress
            max={1}
            value={model.progress === null ? undefined : model.progress}
            aria-label={model.stage || "Operation progress"}
          />
          {model.hardware && (
            <p className="caption">
              Keep the programmer connected until the operation finishes.
            </p>
          )}
        </div>
      )}
    </footer>
  );
}
export function USBDiagnostics({ model }: { model: AppModel }) {
  const summary = model.usbData ? usbSummary(model.usbData) : null;
  const settingsLocked = model.busy || !!model.usbReport;
  return (
    <Modal
      title="USB Diagnostics"
      className="usb-modal"
      onCancel={model.busy ? undefined : () => model.setUsbOpen(false)}
      footer={
        <>
          <button
            data-cancel
            disabled={model.busy}
            onClick={() => model.setUsbOpen(false)}
          >
            Close
          </button>
          <span className="grow" />
          {model.usbReport ? (
            <>
              <button disabled={model.busy} onClick={model.resetUsb}>
                New Test
              </button>
              <button
                disabled={model.busy}
                onClick={() => void model.copyReport()}
              >
                Copy Report
              </button>
              <button
                disabled={model.busy}
                onClick={() => void model.saveReport()}
              >
                Save Report…
              </button>
            </>
          ) : (
            <button
              className="primary"
              disabled={model.busy}
              onClick={() => void model.diagnose()}
            >
              {model.usbSleep ? "Run Sleep Experiment" : "Test Connection"}
            </button>
          )}
        </>
      }
    >
      <p>
        Check the connection between your computer and T76, with any USB cable,
        hub or dock.
      </p>
      <Group title="Before you start" icon={<Usb size={14} />}>
        <p>
          Remove the chip and leave one T76 connected. Reconnect the cable at
          the programmer before each test, then keep it connected until the test
          finishes.
        </p>
      </Group>
      <fieldset className="unstyled usb-settings" disabled={settingsLocked}>
        <label>
          Connected through
          <select
            value={model.usbConnection}
            onChange={(e) => model.setUsbConnection(e.target.value)}
          >
            <option value="unknown">Not sure</option>
            <option value="direct">Direct to computer</option>
            <option value="hub">USB hub</option>
            <option value="dock">Docking station</option>
            <option value="adapter">USB adapter</option>
          </select>
        </label>
        <input
          aria-label="Connection notes (optional)"
          placeholder="Cable, adapter or dock model; multiple devices in the chain"
          maxLength={240}
          value={model.usbNotes}
          onChange={(e) => model.setUsbNotes(e.target.value)}
        />
        <p className="caption">
          This description is supplied by you. USB speed below is measured by
          the operating system.
        </p>
      </fieldset>
      <Disclosure title="Advanced test">
        <label className="checkbox">
          <input
            type="checkbox"
            disabled={settingsLocked}
            checked={model.usbSleep}
            onChange={(e) => model.setUsbSleep(e.target.checked)}
          />
          Temporarily disable programmer USB sleep
        </label>
        <p className="caption">
          For USB 3 troubleshooting. Temporarily changes device-initiated sleep
          (U1/U2), then restores it. The computer can still request sleep.
          Reconnect the T76 after this experiment. Start with the standard test.
        </p>
      </Disclosure>
      {model.busy ? (
        <p className="row">
          <LoaderCircle size={17} className="spin" />
          Testing USB… Keep the T76 connected.
        </p>
      ) : summary ? (
        <div className="usb-result">
          <h3 className={summary.passed ? "success" : "warning"}>
            {summary.passed ? (
              <CheckCircle2 size={17} />
            ) : (
              <AlertTriangle size={17} />
            )}{" "}
            {summary.title}
          </h3>
          <div className="row">
            <span>{summary.speed}</span>
            <span className="grow" />
            <span>Firmware: {summary.firmware}</span>
          </div>
          {[
            ["Programmer detection", summary.found],
            ["USB interface", summary.claimed],
            [
              `Information replies: ${summary.successful} of 4`,
              summary.complete,
            ],
          ].map(([title, passed]) => (
            <div className="row" key={String(title)}>
              {passed ? <CheckCircle2 size={14} /> : <AlertCircle size={14} />}
              <span>{title}</span>
              <span className="grow" />
              <span className="muted">
                {passed ? "Passed" : "Not completed"}
              </span>
            </div>
          ))}
          <p>{summary.advice}</p>
        </div>
      ) : (
        <p>
          The test checks programmer information before and after idle pauses.
          It does not read, erase or program a chip.
        </p>
      )}
      {model.usbReport && (
        <Disclosure title="Technical report">
          <pre className="technical-report" tabIndex={0}>
            {model.usbReport}
          </pre>
        </Disclosure>
      )}
      <p className="caption">
        Reports stay on your computer until you copy or save them. They include
        your optional connection notes, but no programmer serial number or chip
        contents.
      </p>
      <USBSetupGuide />
    </Modal>
  );
}
export function USBSetupGuide() {
  return (
    <Disclosure title="USB setup and recovery">
      <div className="usb-guide caption">
        <h3>Windows · WinUSB</h3>
        <ol>
          <li>
            Close Xgpro and other programmer apps. In Device Manager, open the
            T76 properties and record its current driver name, provider and
            version.
          </li>
          <li>
            If WinUSB is missing, get Zadig only from the official site:
            zadig.akeo.ie. Its signature should identify Akeo Consulting.
          </li>
          <li>
            In Zadig, use Options → List All Devices if needed. Select only the
            T76 and confirm USB ID A466:1A86. Choose WinUSB, then Install Driver
            or Replace Driver. Reconnect the T76 and use Connect / Refresh.
          </li>
          <li>
            Changing this driver can affect Xgpro. To restore it, use Device
            Manager → T76 → Properties → Driver → Roll Back Driver, or reinstall
            the original vendor driver you recorded.
          </li>
        </ol>
        <p>
          XGecu Pro checks the connection; driver installation remains a manual
          step.
        </p>
        <h3>Linux · udev</h3>
        <p>
          The DEB installs the included 70-xgecu-pro.rules. For AppImage, copy
          that file into /etc/udev/rules.d/ with administrator rights. The rule
          grants the active local desktop user access only to USB vendor a466,
          product 1a86.
        </p>
        <p>
          Reload with <code>sudo udevadm control --reload-rules</code>, then
          unplug and reconnect the T76. Run XGecu Pro as your ordinary desktop
          user.
        </p>
      </div>
    </Disclosure>
  );
}
