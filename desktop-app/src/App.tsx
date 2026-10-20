import { useEffect, useState } from "react";
import { AlertTriangle, Cpu, FileText, ListChecks } from "lucide-react";
import { createBridge } from "./bridge";
import {
  Activity,
  HexEditor,
  Modal,
  OperationStatus,
  Program,
  Sidebar,
  USBDiagnostics,
} from "./components";
import { errorMessage } from "./policy";
import { useApp } from "./useApp";
import type { DesktopBridge } from "./types";

function DesktopApp({ bridge }: { bridge: DesktopBridge }) {
  const model = useApp(bridge);
  useEffect(() => {
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const update = () => {
      document.documentElement.dataset.theme =
        model.settings.theme === "system"
          ? media.matches
            ? "dark"
            : "light"
          : model.settings.theme;
    };
    update();
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, [model.settings.theme]);
  return (
    <div className={`app ${bridge.preview ? "is-preview" : ""}`}>
      {bridge.preview && (
        <div className="preview-banner">
          Browser preview · display fixtures only · no USB hardware
        </div>
      )}
      <Sidebar model={model} />
      <main className="detail">
        <div className="tab-toolbar">
          <div className="segmented tabs" role="tablist" aria-label="Workspace">
            {[
              ["program", "Program", Cpu],
              ["hex", "Hex Editor", FileText],
              ["activity", "Activity", ListChecks],
            ].map(([id, label, Icon]) => (
              <button
                key={String(id)}
                role="tab"
                id={`tab-${id}`}
                aria-controls={`panel-${id}`}
                aria-selected={model.tab === id}
                tabIndex={model.tab === id ? 0 : -1}
                onKeyDown={(e) => {
                  if (
                    ["ArrowLeft", "ArrowRight", "Home", "End"].includes(e.key)
                  ) {
                    e.preventDefault();
                    const tabs = ["program", "hex", "activity"];
                    const i = tabs.indexOf(model.tab);
                    const next =
                      e.key === "Home"
                        ? "program"
                        : e.key === "End"
                          ? "activity"
                          : tabs[(i + (e.key === "ArrowRight" ? 1 : 2)) % 3];
                    model.setTab(next);
                    document.getElementById(`tab-${next}`)?.focus();
                  }
                }}
                onClick={() => model.setTab(String(id))}
              >
                {typeof Icon !== "string" && <Icon size={14} />} {String(label)}
              </button>
            ))}
          </div>
        </div>
        <div
          className="tab-panel"
          role="tabpanel"
          id={`panel-${model.tab}`}
          aria-labelledby={`tab-${model.tab}`}
        >
          {model.tab === "program" ? (
            <Program model={model} />
          ) : model.tab === "hex" ? (
            <HexEditor model={model} />
          ) : (
            <Activity model={model} />
          )}
        </div>
        <OperationStatus model={model} />
      </main>
      {model.usbOpen && <USBDiagnostics model={model} />}
      {model.confirmation && (
        <Modal
          title={model.confirmation.title}
          preventEnter
          onCancel={() => void model.resolve(false)}
          footer={
            <>
              <span className="grow" />
              <button data-cancel onClick={() => void model.resolve(false)}>
                Cancel
              </button>
              <button
                className={
                  model.confirmation.destructive ? "danger-primary" : "primary"
                }
                onClick={() => void model.resolve(true)}
              >
                {model.confirmation.action}
              </button>
            </>
          }
        >
          <AlertTriangle className="confirmation-icon" size={31} />
          <p className="confirmation-message">{model.confirmation.message}</p>
        </Modal>
      )}
    </div>
  );
}
export default function App() {
  const [bridge, setBridge] = useState<DesktopBridge | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let disposed = false;
    createBridge()
      .then((b) => {
        if (!disposed) setBridge(b);
      })
      .catch((e) => {
        if (!disposed) setError(errorMessage(e));
      });
    return () => {
      disposed = true;
    };
  }, []);
  return bridge ? (
    <DesktopApp bridge={bridge} />
  ) : (
    <main className="loading-screen">
      <h2>XGecu Pro</h2>
      <p>{error || "Opening the programmer workspace…"}</p>
    </main>
  );
}
