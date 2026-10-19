export type Theme = "system" | "light" | "dark";
export interface Settings {
  databasePath: string;
  favorites: string[];
  theme: Theme;
}
export type ProgrammerOperation =
  | "connect"
  | "search"
  | "describe"
  | "autodetect"
  | "check"
  | "read"
  | "verify"
  | "blank"
  | "erase"
  | "usb_diagnose";
export interface ProgrammerRequest {
  operation: ProgrammerOperation;
  chip?: string;
  query?: string;
  file?: string;
  database?: string;
  limit?: number;
  disableDeviceU1U2?: boolean;
}
export interface ChipDetails {
  name: string;
  package: string;
  pins: number;
  code_bytes: number;
  data_bytes: number;
  data2_bytes: number;
  page_bytes: number;
  chip_id?: string;
  blank_value: string;
  can_erase: boolean;
}
export interface ProgrammerResult extends Partial<ChipDetails> {
  ok?: boolean;
  op?: string;
  model?: string;
  fw?: string;
  link?: string;
  n?: number;
  hits?: string[];
  more?: boolean;
  id?: string;
  matches?: boolean | string[];
  stable?: boolean;
  blank?: boolean;
  chip_id_checked?: boolean;
  pins_checked?: boolean;
  open_pins?: number[];
  first_mismatch?: number;
  report?: DiagnosticReport;
  [key: string]: unknown;
}
export interface PreparedProgram {
  token: string;
  chip: string;
  file: string;
  bytes: number;
}
export type BufferOperation =
  | "open"
  | "save"
  | "page"
  | "edit"
  | "fill"
  | "copy"
  | "export"
  | "find_hex"
  | "find_ascii"
  | "undo"
  | "redo"
  | "compare"
  | "state";
export interface BufferRequest {
  operation: BufferOperation;
  file?: string;
  offset?: number;
  count?: number;
  start?: number;
  end?: number;
  destination?: number;
  value?: number;
  query?: string;
  originChip?: string;
}
export interface BufferReply {
  size: number;
  offset: number;
  bytes: number[];
  sha256: string;
  dirty: boolean;
  canUndo: boolean;
  canRedo: boolean;
  source?: string;
  originChip?: string;
  foundOffset?: number;
  firstMismatch?: number;
  otherBytes?: number;
  matches?: boolean;
  savedPath?: string;
}
export interface OperationEvent {
  stage?: string;
  progress?: { done: number; total: number };
  warn?: unknown;
  note?: string;
}
export interface AppFailure {
  code: string;
  message: string;
  hint?: string;
}
export interface DiagnosticReport {
  profile?: string;
  passed?: boolean;
  opening?: { interface_claimed?: boolean; configurations?: unknown[] };
  probes?: { error?: string; firmware?: string; idle_ms?: number }[];
  error?: string;
  restore_error?: string;
  link?: string;
  bos_hex?: string;
}
export interface DesktopBridge {
  readonly preview: boolean;
  settings(): Promise<Settings>;
  saveSettings(settings: Settings): Promise<Settings>;
  programmer(request: ProgrammerRequest): Promise<ProgrammerResult>;
  prepare(
    chip: string,
    file: string,
    database: string,
  ): Promise<PreparedProgram>;
  commit(token: string): Promise<ProgrammerResult>;
  cancel(token: string): Promise<void>;
  buffer(request: BufferRequest): Promise<BufferReply>;
  open(title: string, directory?: boolean): Promise<string | null>;
  inspectFile(file: string): Promise<{ bytes: number }>;
  save(title: string, defaultPath: string): Promise<string | null>;
  saveText(file: string, contents: string): Promise<void>;
  allowClose(): Promise<void>;
  subscribe(
    callback: (event: OperationEvent) => void,
    close: () => void,
  ): Promise<() => void>;
}
export const emptyBuffer: BufferReply = {
  size: 0,
  offset: 0,
  bytes: [],
  sha256: "",
  dirty: false,
  canUndo: false,
  canRedo: false,
};
