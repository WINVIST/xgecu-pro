// SPDX-FileCopyrightText: 2026 John Fabienke
// SPDX-License-Identifier: MIT

//! File formats for memory images: raw binary, Intel HEX, and Motorola
//! S-record. This is the `Format` data abstraction from the trait-model design
//! (docs/rust-trait-model.md §4) — the CLI reads/writes chip images in any of
//! these, instead of only raw bytes.
//!
//! `parse` turns file bytes into a flat [`Image`] (record addresses honored,
//! gaps filled with [`PAD`]); `emit` renders an image back out. Addressed
//! formats are assumed to start at address 0 — the common case for a chip dump;
//! a record set that starts higher is front-padded to keep addresses absolute.

use std::path::Path;

use crate::device::Image;
use crate::error::{Error, Result};

/// Fill byte for gaps and short images: 0xFF, the erased state of EPROM/flash.
pub const PAD: u8 = 0xFF;
pub const MAX_IMAGE_BYTES: usize = 256 << 20;

/// A supported image file format.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    /// Flat binary — bytes are the image.
    Raw,
    /// Intel HEX (`:` records, 16-bit + extended-linear/segment addressing).
    IHex,
    /// Motorola S-record (S1/S2/S3 data records).
    SRec,
}

impl Format {
    /// Pick a format from a file extension (`.hex`→IHex, `.s19/.srec/…`→SRec,
    /// otherwise Raw). Used for both output naming and input selection.
    pub fn from_path(path: &Path) -> Format {
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .map(str::to_ascii_lowercase)
            .unwrap_or_default();
        match ext.as_str() {
            "hex" | "ihex" | "ihx" => Format::IHex,
            "s19" | "s28" | "s37" | "srec" | "s-record" | "mot" | "s1" | "s2" | "s3" => {
                Format::SRec
            }
            _ => Format::Raw,
        }
    }

    /// Sniff a plausible first record, so a binary image beginning with ASCII
    /// `S` or `:` is not mistaken for a text format.
    ///
    /// ```
    /// use minipro_core::format::Format;
    /// assert_eq!(Format::detect(b":00000001FF\n"), Format::IHex);
    /// assert_eq!(Format::detect(b"S9030000FC\n"), Format::SRec);
    /// assert_eq!(Format::detect(&[0xde, 0xad]), Format::Raw);
    /// ```
    pub fn detect(bytes: &[u8]) -> Format {
        let first = bytes
            .split(|&b| b == b'\n')
            .find(|line| line.iter().any(|b| !b.is_ascii_whitespace()))
            .unwrap_or_default();
        let line = first.trim_ascii();
        if line.len() >= 11
            && line[0] == b':'
            && line[1..].len() % 2 == 0
            && line[1..].iter().all(u8::is_ascii_hexdigit)
        {
            Format::IHex
        } else if line.len() >= 10
            && line[0] == b'S'
            && line[1].is_ascii_digit()
            && line[2..].len() % 2 == 0
            && line[2..].iter().all(u8::is_ascii_hexdigit)
        {
            Format::SRec
        } else {
            Format::Raw
        }
    }

    /// Parse file bytes into a flat image. `pad` fills gaps between addressed
    /// records (use the chip's blank value; [`PAD`] is the usual `0xFF`).
    ///
    /// Round-trips with [`Format::emit`]:
    /// ```
    /// use minipro_core::format::{Format, PAD};
    /// let img = Format::Raw.parse(&[0xde, 0xad, 0xbe, 0xef], PAD).unwrap();
    /// let hex = Format::IHex.emit(&img);
    /// let back = Format::IHex.parse(&hex, PAD).unwrap();
    /// assert_eq!(back.bytes, img.bytes);
    /// ```
    pub fn parse(self, bytes: &[u8], pad: u8) -> Result<Image> {
        self.parse_with_limit(bytes, pad, MAX_IMAGE_BYTES)
    }

    /// Parse without allowing a sparse addressed record to allocate beyond
    /// the selected chip's capacity.
    pub fn parse_with_limit(self, bytes: &[u8], pad: u8, max_len: usize) -> Result<Image> {
        match self {
            Format::Raw if bytes.len() <= max_len => Ok(Image {
                bytes: bytes.to_vec(),
            }),
            Format::Raw => Err(Error::Format("image exceeds selected chip capacity".into())),
            Format::IHex => parse_ihex(bytes, pad, max_len),
            Format::SRec => parse_srec(bytes, pad, max_len),
        }
    }

    /// Render an image to file bytes in this format.
    pub fn emit(self, img: &Image) -> Vec<u8> {
        match self {
            Format::Raw => img.bytes.clone(),
            Format::IHex => emit_ihex(&img.bytes),
            Format::SRec => emit_srec(&img.bytes),
        }
    }
}

// ---- shared helpers --------------------------------------------------------

/// Decode a run of hex-digit pairs into bytes; `None` on odd length or a
/// non-hex character.
fn decode_hex(s: &str) -> Option<Vec<u8>> {
    let s = s.trim();
    if s.len() % 2 != 0 {
        return None;
    }
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(s.len() / 2);
    for pair in b.chunks(2) {
        let hi = (pair[0] as char).to_digit(16)?;
        let lo = (pair[1] as char).to_digit(16)?;
        out.push((hi * 16 + lo) as u8);
    }
    Some(out)
}

/// Apply a checked record immediately, without retaining every input record.
/// Empty data records carry no image bytes, even if their address is high.
fn apply_record(
    out: &mut Vec<u8>,
    address: u32,
    data: &[u8],
    pad: u8,
    max_len: usize,
) -> Result<()> {
    if data.is_empty() {
        return Ok(());
    }
    let start = address as usize;
    let end = start
        .checked_add(data.len())
        .ok_or_else(|| Error::Format("record address overflow".into()))?;
    if end > max_len {
        return Err(Error::Format(
            "image address exceeds selected chip capacity".into(),
        ));
    }
    if out.len() < end {
        out.resize(end, pad);
    }
    out[start..end].copy_from_slice(data);
    Ok(())
}

fn hex_byte(out: &mut String, b: u8) {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    out.push(HEX[(b >> 4) as usize] as char);
    out.push(HEX[(b & 0x0f) as usize] as char);
}

// ---- Intel HEX -------------------------------------------------------------

fn parse_ihex(bytes: &[u8], pad: u8, max_len: usize) -> Result<Image> {
    let text = std::str::from_utf8(bytes)
        .map_err(|_| Error::Format("Intel HEX is not valid ASCII".into()))?;
    let mut base: u32 = 0;
    let mut image = Vec::new();
    for (i, raw) in text.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        let n = i + 1;
        let rest = line
            .strip_prefix(':')
            .ok_or_else(|| Error::Format(format!("Intel HEX line {n}: missing ':'")))?;
        let rec = decode_hex(rest)
            .ok_or_else(|| Error::Format(format!("Intel HEX line {n}: bad hex")))?;
        if rec.len() < 5 {
            return Err(Error::Format(format!(
                "Intel HEX line {n}: record too short"
            )));
        }
        let len = rec[0] as usize;
        if rec.len() != 5 + len {
            return Err(Error::Format(format!(
                "Intel HEX line {n}: length byte mismatch"
            )));
        }
        if rec.iter().fold(0u8, |a, &b| a.wrapping_add(b)) != 0 {
            return Err(Error::Format(format!("Intel HEX line {n}: checksum error")));
        }
        let addr = u16::from_be_bytes([rec[1], rec[2]]) as u32;
        let data = &rec[4..4 + len];
        match rec[3] {
            0x00 => {
                let absolute = base.checked_add(addr).ok_or_else(|| {
                    Error::Format(format!("Intel HEX line {n}: address overflow"))
                })?;
                apply_record(&mut image, absolute, data, pad, max_len)?;
            }
            0x01 if len == 0 => break,
            0x02 if len == 2 => base = (u16::from_be_bytes([data[0], data[1]]) as u32) << 4,
            0x04 if len == 2 => base = (u16::from_be_bytes([data[0], data[1]]) as u32) << 16,
            0x03 | 0x05 if len == 4 => {} // start-address records
            0x01..=0x05 => {
                return Err(Error::Format(format!(
                    "Intel HEX line {n}: wrong record length"
                )))
            }
            t => {
                return Err(Error::Format(format!(
                    "Intel HEX line {n}: unknown record type {t:#x}"
                )))
            }
        }
    }
    Ok(Image { bytes: image })
}

/// Write one Intel HEX record body `[len, addr_hi, addr_lo, type, data…]` with
/// its trailing checksum (two's-complement of the byte sum).
fn ihex_record(out: &mut String, body: &[u8]) {
    let cksum = body
        .iter()
        .fold(0u8, |a, &b| a.wrapping_add(b))
        .wrapping_neg();
    out.push(':');
    for &b in body {
        hex_byte(out, b);
    }
    hex_byte(out, cksum);
    out.push('\n');
}

fn emit_ihex(data: &[u8]) -> Vec<u8> {
    let mut out = String::new();
    let mut upper: u16 = 0;
    for (i, chunk) in data.chunks(16).enumerate() {
        let addr = (i * 16) as u32;
        let hi = (addr >> 16) as u16;
        if hi != upper {
            upper = hi;
            ihex_record(
                &mut out,
                &[0x02, 0x00, 0x00, 0x04, (hi >> 8) as u8, hi as u8],
            );
        }
        let mut body = Vec::with_capacity(4 + chunk.len());
        body.extend_from_slice(&[chunk.len() as u8, (addr >> 8) as u8, addr as u8, 0x00]);
        body.extend_from_slice(chunk);
        ihex_record(&mut out, &body);
    }
    ihex_record(&mut out, &[0x00, 0x00, 0x00, 0x01]); // EOF
    out.into_bytes()
}

// ---- Motorola S-record -----------------------------------------------------

fn parse_srec(bytes: &[u8], pad: u8, max_len: usize) -> Result<Image> {
    let text = std::str::from_utf8(bytes)
        .map_err(|_| Error::Format("S-record is not valid ASCII".into()))?;
    let mut image = Vec::new();
    for (i, raw) in text.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        let n = i + 1;
        let bytes = line.as_bytes();
        if bytes[0] != b'S' || line.len() < 4 {
            return Err(Error::Format(format!("S-record line {n}: not an S-record")));
        }
        let rec = decode_hex(&line[2..])
            .ok_or_else(|| Error::Format(format!("S-record line {n}: bad hex")))?;
        let count = *rec
            .first()
            .ok_or_else(|| Error::Format(format!("S-record line {n}: empty")))?
            as usize;
        if rec.len() != 1 + count {
            return Err(Error::Format(format!(
                "S-record line {n}: count byte mismatch"
            )));
        }
        let sum = rec[..rec.len() - 1]
            .iter()
            .fold(0u8, |a, &b| a.wrapping_add(b));
        if !sum != rec[rec.len() - 1] {
            return Err(Error::Format(format!("S-record line {n}: checksum error")));
        }
        // Only S1/S2/S3 carry image data; S0 header, S5/6 counts, S7/8/9
        // terminators are skipped.
        let addr_len = match bytes[1] {
            b'1' => 2,
            b'2' => 3,
            b'3' => 4,
            b'0' | b'4' | b'5' | b'6' | b'7' | b'8' | b'9' => continue,
            t => {
                return Err(Error::Format(format!(
                    "S-record line {n}: unknown type S{}",
                    t as char
                )))
            }
        };
        if count < addr_len + 1 {
            return Err(Error::Format(format!(
                "S-record line {n}: record too short"
            )));
        }
        let addr = rec[1..1 + addr_len]
            .iter()
            .fold(0u32, |a, &b| (a << 8) | b as u32);
        apply_record(
            &mut image,
            addr,
            &rec[1 + addr_len..rec.len() - 1],
            pad,
            max_len,
        )?;
    }
    Ok(Image { bytes: image })
}

/// Write one S-record of `kind` (`b'1'`, `b'9'`, …): `S<kind><count><addr><data><cksum>`.
fn srec_record(out: &mut String, kind: u8, addr: u32, data: &[u8], addr_len: usize) {
    let mut body = Vec::with_capacity(1 + addr_len + data.len());
    body.push((addr_len + data.len() + 1) as u8); // count: addr + data + checksum
    for i in (0..addr_len).rev() {
        body.push((addr >> (8 * i)) as u8);
    }
    body.extend_from_slice(data);
    let cksum = !body.iter().fold(0u8, |a, &b| a.wrapping_add(b));
    out.push('S');
    out.push(kind as char);
    for &b in &body {
        hex_byte(out, b);
    }
    hex_byte(out, cksum);
    out.push('\n');
}

fn emit_srec(data: &[u8]) -> Vec<u8> {
    // Widen the address field (and matching terminator) to fit the image.
    let (dtype, addr_len, term) = if data.len() <= 0x1_0000 {
        (b'1', 2, b'9')
    } else if data.len() <= 0x100_0000 {
        (b'2', 3, b'8')
    } else {
        (b'3', 4, b'7')
    };
    let mut out = String::new();
    srec_record(&mut out, b'0', 0, b"HDR", 2); // S0 header
    for (i, chunk) in data.chunks(16).enumerate() {
        srec_record(&mut out, dtype, (i * 16) as u32, chunk, addr_len);
    }
    srec_record(&mut out, term, 0, &[], addr_len); // terminator, start address 0
    out.into_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn img(bytes: &[u8]) -> Image {
        Image {
            bytes: bytes.to_vec(),
        }
    }

    #[test]
    fn from_path_and_detect() {
        assert_eq!(Format::from_path(Path::new("d.hex")), Format::IHex);
        assert_eq!(Format::from_path(Path::new("d.s19")), Format::SRec);
        assert_eq!(Format::from_path(Path::new("d.bin")), Format::Raw);
        assert_eq!(Format::from_path(Path::new("d")), Format::Raw);
        assert_eq!(Format::detect(b"\n  :00000001FF\n"), Format::IHex);
        assert_eq!(Format::detect(b"S9030000FC\n"), Format::SRec);
        assert_eq!(Format::detect(b"Sample binary image"), Format::Raw);
        assert_eq!(Format::detect(b":not a record"), Format::Raw);
        assert_eq!(Format::detect(&[0x00, 0x01, 0x02]), Format::Raw);
    }

    #[test]
    fn malformed_text_images_do_not_panic_or_exceed_limit() {
        let source = img(&[0x12, 0x34, 0x56, 0x78]);
        for format in [Format::IHex, Format::SRec] {
            let valid = format.emit(&source);
            for position in 0..valid.len() {
                for replacement in [0, b'F', b':', b'\n', 0xff] {
                    let mut mutated = valid.clone();
                    mutated[position] = replacement;
                    if let Ok(image) = format.parse_with_limit(&mutated, PAD, 64) {
                        assert!(image.bytes.len() <= 64);
                    }
                }
            }
        }
    }

    #[test]
    fn records_are_applied_with_an_immediate_capacity_check() {
        let mut bytes = Vec::new();
        apply_record(&mut bytes, u32::MAX, &[], PAD, 8).unwrap();
        assert!(bytes.is_empty());
        apply_record(&mut bytes, 4, &[0x12, 0x34], PAD, 8).unwrap();
        assert_eq!(bytes, [PAD, PAD, PAD, PAD, 0x12, 0x34]);
        apply_record(&mut bytes, 5, &[0x56], PAD, 8).unwrap();
        assert_eq!(bytes[5], 0x56);
        assert!(apply_record(&mut bytes, 8, &[0x99], PAD, 8).is_err());
        assert_eq!(bytes.len(), 6);

        let empty_records = b":0000000000\n".repeat(10_000);
        assert!(Format::IHex
            .parse_with_limit(&empty_records, PAD, 8)
            .unwrap()
            .bytes
            .is_empty());
        let empty_srecords = b"S1030000FC\n".repeat(10_000);
        assert!(Format::SRec
            .parse_with_limit(&empty_srecords, PAD, 8)
            .unwrap()
            .bytes
            .is_empty());
    }

    #[test]
    fn ihex_known_vector() {
        // Classic ":00000001FF" is the EOF record; a data record before it.
        // len 03, addr 0000, type 00, data 01 02 03, sum 0x09 -> cksum 0xF7.
        let hex = ":03000000010203F7\n:00000001FF\n";
        let image = Format::IHex.parse(hex.as_bytes(), PAD).unwrap();
        assert_eq!(image.bytes, vec![0x01, 0x02, 0x03]);
    }

    #[test]
    fn ihex_rejects_bad_checksum() {
        let hex = ":03000000010203AA\n:00000001FF\n";
        assert_eq!(
            Format::IHex.parse(hex.as_bytes(), PAD).unwrap_err().code(),
            "format"
        );
    }

    #[test]
    fn srec_known_vector() {
        // S1 record, addr 0000, data 01 02 03, checksum.
        // count=06, sum(06 00 00 01 02 03)=0x0c, cksum=0xF3.
        let srec = "S106000001020".to_string() + "3F3\nS9030000FC\n";
        let image = Format::SRec.parse(srec.as_bytes(), PAD).unwrap();
        assert_eq!(image.bytes, vec![0x01, 0x02, 0x03]);
    }

    #[test]
    fn ihex_roundtrips() {
        let data: Vec<u8> = (0..=255u8).chain(0..100).collect();
        let bytes = Format::IHex.emit(&img(&data));
        // Emitted text is ASCII and starts with a record marker.
        assert!(bytes.starts_with(b":"));
        let back = Format::IHex.parse(&bytes, PAD).unwrap();
        assert_eq!(back.bytes, data);
    }

    #[test]
    fn srec_roundtrips() {
        let data: Vec<u8> = (0..500u32).map(|i| (i * 7) as u8).collect();
        let bytes = Format::SRec.emit(&img(&data));
        assert!(bytes.starts_with(b"S"));
        let back = Format::SRec.parse(&bytes, PAD).unwrap();
        assert_eq!(back.bytes, data);
    }

    #[test]
    fn ihex_roundtrips_across_64k_boundary() {
        // Force an extended-linear-address record.
        let data = vec![0xABu8; 0x1_0020];
        let bytes = Format::IHex.emit(&img(&data));
        assert!(String::from_utf8_lossy(&bytes).contains(":02000004")); // type-04 record
        assert_eq!(Format::IHex.parse(&bytes, PAD).unwrap().bytes, data);
    }

    #[test]
    fn raw_is_identity() {
        let data = vec![0xde, 0xad, 0xbe, 0xef];
        assert_eq!(Format::Raw.emit(&img(&data)), data);
        assert_eq!(Format::Raw.parse(&data, PAD).unwrap().bytes, data);
    }

    #[test]
    fn gaps_are_pad_filled() {
        // Two data records with a hole between them -> hole is 0xFF.
        // rec1 @0000: 0xAA (len 01, cksum: 01+00+00+00+AA=AB -> neg 55)
        // rec2 @0004: 0xBB (len 01, addr 0004, cksum: 01+00+04+00+BB=C0 -> neg 40)
        let hex = ":01000000AA55\n:0100040".to_string() + "0BB40\n:00000001FF\n";
        let image = Format::IHex.parse(hex.as_bytes(), PAD).unwrap();
        assert_eq!(image.bytes, vec![0xAA, PAD, PAD, PAD, 0xBB]);
    }

    #[test]
    fn malformed_short_records_are_errors() {
        assert_eq!(
            Format::IHex
                .parse(b":00000002FE\n", PAD)
                .unwrap_err()
                .code(),
            "format"
        );
        assert_eq!(
            Format::SRec.parse(b"S101FE\n", PAD).unwrap_err().code(),
            "format"
        );
    }

    #[test]
    fn sparse_address_cannot_grow_image_past_limit() {
        let sparse = b":02000004FFFFFC\n:01000000AA55\n";
        assert_eq!(
            Format::IHex
                .parse_with_limit(sparse, PAD, 65536)
                .unwrap_err()
                .code(),
            "format"
        );
    }
}
