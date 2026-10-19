import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { Modal } from "./components";
describe("destructive confirmation keyboard behavior", () => {
  it("focuses Cancel and treats Enter on every control as cancellation", () => {
    const cancel = vi.fn();
    const program = vi.fn();
    render(
      <Modal
        title="Program MX25L51245G?"
        preventEnter
        onCancel={cancel}
        footer={
          <>
            <button data-cancel onClick={cancel}>
              Cancel
            </button>
            <button onClick={program}>Program and Verify</button>
          </>
        }
      >
        <p>Preflight passed.</p>
      </Modal>,
    );
    expect(screen.getByRole("button", { name: "Cancel" })).toHaveFocus();
    const destructive = screen.getByRole("button", {
      name: "Program and Verify",
    });
    destructive.focus();
    fireEvent.keyDown(destructive, { key: "Enter" });
    expect(cancel).toHaveBeenCalledTimes(1);
    expect(program).not.toHaveBeenCalled();
  });
  it("permits a deliberate pointer activation of the destructive action", () => {
    const program = vi.fn();
    render(
      <Modal
        title="Erase?"
        preventEnter
        footer={
          <>
            <button data-cancel>Cancel</button>
            <button onClick={program}>Erase</button>
          </>
        }
      >
        <p>Save a dump first.</p>
      </Modal>,
    );
    fireEvent.click(screen.getByRole("button", { name: "Erase" }));
    expect(program).toHaveBeenCalledOnce();
  });
});
