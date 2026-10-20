import { describe, expect, it } from "vitest";
import {
  canRead,
  canWrite,
  chipDetails,
  MAX_IMAGE,
  parseHex,
  usbSummary,
} from "./policy";
import type { ChipDetails } from "./types";
const chip: ChipDetails = {
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
describe("database-qualified chip policy", () => {
  it("enables reads through 2 GiB and requires a matching, connected T76", () => {
    expect(canRead(chip.name, { ...chip, code_bytes: MAX_IMAGE }, true)).toBe(
      true,
    );
    for (const details of [
      { ...chip, code_bytes: MAX_IMAGE + 1 },
      { ...chip, code_bytes: 0 },
      { ...chip, pins: 0 },
      { ...chip, name: "OTHER" },
    ])
      expect(canRead(chip.name, details, true)).toBe(false);
    expect(canRead(chip.name, chip, false)).toBe(false);
  });
  it("never enables mutations without an electronic ID", () => {
    expect(canWrite(chip.name, chip, true)).toBe(true);
    expect(canWrite(chip.name, { ...chip, chip_id: undefined }, true)).toBe(
      false,
    );
  });
  it("rejects incomplete or incorrectly typed database replies", () => {
    expect(() => chipDetails({ ...chip, pins: "16" })).toThrow(/incomplete/);
    expect(() => chipDetails({ ...chip, page_bytes: undefined })).toThrow(
      /incomplete/,
    );
  });
});
describe("address validation", () => {
  it("accepts explicit HEX addresses but rejects partial parsing and unsafe integers", () => {
    expect(parseHex(" 0xFF ")).toBe(255);
    for (const value of ["12oops", "-1", "1.2", "", "FFFFFFFFFFFFFFFF"])
      expect(() => parseHex(value)).toThrow();
  });
});
describe("USB diagnostic summary", () => {
  it("requires all timed exchanges, one firmware, and a claimed interface to report passed", () => {
    const report = {
      passed: true,
      opening: { interface_claimed: true },
      link: "High",
      probes: [0, 100, 1000, 3000].map((idle_ms) => ({
        idle_ms,
        firmware: "00.1.07",
      })),
    };
    expect(usbSummary(report).passed).toBe(true);
    expect(
      usbSummary({ ...report, probes: report.probes.slice(0, 3) }).passed,
    ).toBe(false);
    expect(
      usbSummary({ ...report, opening: { interface_claimed: false } }).passed,
    ).toBe(false);
    expect(
      usbSummary({ ...report, restore_error: "restore failed" }).title,
    ).toMatch(/could not be restored/);
  });
  it("reports missing hardware separately from driver/interface failures", () => {
    expect(usbSummary({ error: "no T76 connected" }).title).toBe(
      "T76 was not found",
    );
    expect(
      usbSummary({ link: "High", error: "access denied" }).title,
    ).toContain("interface did not open");
  });
});
