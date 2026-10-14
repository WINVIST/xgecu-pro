// SPDX-License-Identifier: MIT

//! Bounded-memory format I/O. Callers prepare private temporary files and
//! publish their outputs atomically only after all validation succeeds.

use std::io::{BufRead, Read, Seek, SeekFrom, Write};

use super::{decode_hex, ihex_record, srec_record, Format, MAX_STREAMED_IMAGE_BYTES};
use crate::error::{Error, Result};

const CHUNK_BYTES: usize = 64 * 1024;
const MAX_RECORD_BYTES: usize = 1024;
const MAX_TEXT_BYTES: u64 = MAX_STREAMED_IMAGE_BYTES * 4;

impl Format {
    /// Decode an image into an empty seekable spool. Addressed gaps use `pad`;
    /// later overlapping records replace earlier bytes, as in `parse`.
    /// No buffer grows with image capacity. On error the private spool may
    /// contain partial data and must not be published or used for programming.
    pub fn decode_to<R: BufRead, W: Read + Write + Seek>(
        self,
        input: &mut R,
        output: &mut W,
        pad: u8,
        max_len: u64,
    ) -> Result<u64> {
        check_capacity(max_len)?;
        if output.seek(SeekFrom::End(0))? != 0 {
            return Err(Error::Format("image spool must be empty".into()));
        }
        if self == Self::Raw {
            let mut chunk = [0u8; CHUNK_BYTES];
            let mut total = 0u64;
            loop {
                let available = (max_len - total + 1).min(CHUNK_BYTES as u64) as usize;
                let count = input.read(&mut chunk[..available])?;
                if count == 0 {
                    output.seek(SeekFrom::Start(0))?;
                    return Ok(total);
                }
                if count as u64 > max_len - total {
                    return Err(Error::Format("image exceeds selected chip capacity".into()));
                }
                output.write_all(&chunk[..count])?;
                total += count as u64;
            }
        }

        let mut base = 0u32;
        let mut image_len = 0u64;
        let mut line_number = 0u64;
        let mut text_bytes = 0u64;
        while let Some(line) = read_record_line(input)? {
            line_number += 1;
            text_bytes += line.len() as u64;
            if text_bytes > MAX_TEXT_BYTES {
                return Err(Error::Format("text image exceeds the input limit".into()));
            }
            let text = std::str::from_utf8(&line)
                .map_err(|_| Error::Format("text image is not valid ASCII".into()))?
                .trim();
            if text.is_empty() {
                continue;
            }
            match self {
                Self::IHex => {
                    let rest = text.strip_prefix(':').ok_or_else(|| {
                        Error::Format(format!("Intel HEX line {line_number}: missing ':'"))
                    })?;
                    let record = decode_hex(rest).ok_or_else(|| {
                        Error::Format(format!("Intel HEX line {line_number}: bad hex"))
                    })?;
                    if record.len() < 5 || record.len() != 5 + usize::from(record[0]) {
                        return Err(Error::Format(format!(
                            "Intel HEX line {line_number}: invalid record length"
                        )));
                    }
                    if record.iter().fold(0u8, |sum, byte| sum.wrapping_add(*byte)) != 0 {
                        return Err(Error::Format(format!(
                            "Intel HEX line {line_number}: checksum error"
                        )));
                    }
                    let address = u32::from(u16::from_be_bytes([record[1], record[2]]));
                    let data = &record[4..record.len() - 1];
                    match record[3] {
                        0 => {
                            let absolute = base.checked_add(address).ok_or_else(|| {
                                Error::Format("Intel HEX address overflow".into())
                            })?;
                            apply_record(output, &mut image_len, absolute, data, pad, max_len)?;
                        }
                        1 if data.is_empty() => break,
                        2 if data.len() == 2 => {
                            base = u32::from(u16::from_be_bytes([data[0], data[1]])) << 4;
                        }
                        4 if data.len() == 2 => {
                            base = u32::from(u16::from_be_bytes([data[0], data[1]])) << 16;
                        }
                        3 | 5 if data.len() == 4 => {}
                        _ => {
                            return Err(Error::Format(format!(
                                "Intel HEX line {line_number}: invalid record type or length"
                            )));
                        }
                    }
                }
                Self::SRec => {
                    let bytes = text.as_bytes();
                    if bytes.len() < 4 || bytes[0] != b'S' || !text.is_ascii() {
                        return Err(Error::Format(format!(
                            "S-record line {line_number}: not an S-record"
                        )));
                    }
                    let record = decode_hex(&text[2..]).ok_or_else(|| {
                        Error::Format(format!("S-record line {line_number}: bad hex"))
                    })?;
                    let count = record.first().copied().ok_or_else(|| {
                        Error::Format(format!("S-record line {line_number}: empty"))
                    })? as usize;
                    if record.len() != count + 1 || record.len() < 2 {
                        return Err(Error::Format(format!(
                            "S-record line {line_number}: count byte mismatch"
                        )));
                    }
                    if record.iter().fold(0u8, |sum, byte| sum.wrapping_add(*byte)) != 0xff {
                        return Err(Error::Format(format!(
                            "S-record line {line_number}: checksum error"
                        )));
                    }
                    let address_bytes = match bytes[1] {
                        b'1' => 2,
                        b'2' => 3,
                        b'3' => 4,
                        b'0' | b'4' | b'5' | b'6' | b'7' | b'8' | b'9' => continue,
                        _ => return Err(Error::Format("unknown S-record type".into())),
                    };
                    if count < address_bytes + 1 {
                        return Err(Error::Format("S-record is too short".into()));
                    }
                    let address = record[1..1 + address_bytes]
                        .iter()
                        .fold(0u32, |address, byte| (address << 8) | u32::from(*byte));
                    apply_record(
                        output,
                        &mut image_len,
                        address,
                        &record[1 + address_bytes..record.len() - 1],
                        pad,
                        max_len,
                    )?;
                }
                Self::Raw => return Err(Error::Format("raw format has no text records".into())),
            }
        }
        output.flush()?;
        output.seek(SeekFrom::Start(0))?;
        Ok(image_len)
    }

    /// Emit an exact-length raw spool without retaining the image or encoded
    /// text. A caller can use a BufWriter to batch the small text records.
    pub fn encode_from<R: Read + Seek, W: Write>(
        self,
        input: &mut R,
        output: &mut W,
        len: u64,
    ) -> Result<()> {
        check_capacity(len)?;
        if input.seek(SeekFrom::End(0))? != len {
            return Err(Error::Format("image spool length changed".into()));
        }
        input.seek(SeekFrom::Start(0))?;
        if self == Self::Raw {
            let mut chunk = [0u8; CHUNK_BYTES];
            let mut remaining = len;
            while remaining > 0 {
                let count = remaining.min(CHUNK_BYTES as u64) as usize;
                input.read_exact(&mut chunk[..count])?;
                output.write_all(&chunk[..count])?;
                remaining -= count as u64;
            }
            return Ok(());
        }
        let (data_type, address_bytes, terminator) = if len <= 0x1_0000 {
            (b'1', 2, b'9')
        } else if len <= 0x100_0000 {
            (b'2', 3, b'8')
        } else {
            (b'3', 4, b'7')
        };
        let mut record = String::with_capacity(80);
        if self == Self::SRec {
            srec_record(&mut record, b'0', 0, b"HDR", 2);
            output.write_all(record.as_bytes())?;
        }
        let mut address = 0u32;
        let mut upper = 0u16;
        let mut chunk = [0u8; 16];
        while u64::from(address) < len {
            let count = (len - u64::from(address)).min(16) as usize;
            input.read_exact(&mut chunk[..count])?;
            record.clear();
            match self {
                Self::IHex => {
                    let high = (address >> 16) as u16;
                    if high != upper {
                        upper = high;
                        ihex_record(&mut record, &[2, 0, 0, 4, (high >> 8) as u8, high as u8]);
                    }
                    let mut body = Vec::with_capacity(20);
                    body.extend_from_slice(&[count as u8, (address >> 8) as u8, address as u8, 0]);
                    body.extend_from_slice(&chunk[..count]);
                    ihex_record(&mut record, &body);
                }
                Self::SRec => srec_record(
                    &mut record,
                    data_type,
                    address,
                    &chunk[..count],
                    address_bytes,
                ),
                Self::Raw => return Err(Error::Format("raw format has no text records".into())),
            }
            output.write_all(record.as_bytes())?;
            address += count as u32;
        }
        record.clear();
        match self {
            Self::IHex => ihex_record(&mut record, &[0, 0, 0, 1]),
            Self::SRec => srec_record(&mut record, terminator, 0, &[], address_bytes),
            Self::Raw => return Err(Error::Format("raw format has no text terminator".into())),
        }
        output.write_all(record.as_bytes())?;
        Ok(())
    }
}

fn check_capacity(len: u64) -> Result<()> {
    if len > MAX_STREAMED_IMAGE_BYTES {
        return Err(Error::Format(
            "image exceeds the streamed image limit".into(),
        ));
    }
    Ok(())
}

fn read_record_line<R: BufRead>(input: &mut R) -> Result<Option<Vec<u8>>> {
    let mut line = Vec::with_capacity(128);
    loop {
        let buffer = input.fill_buf()?;
        if buffer.is_empty() {
            return Ok((!line.is_empty()).then_some(line));
        }
        let count = buffer
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(buffer.len(), |index| index + 1);
        if count > MAX_RECORD_BYTES - line.len() {
            return Err(Error::Format("text image record exceeds 1024 bytes".into()));
        }
        let finished = buffer[count - 1] == b'\n';
        line.extend_from_slice(&buffer[..count]);
        input.consume(count);
        if finished {
            return Ok(Some(line));
        }
    }
}

fn apply_record<W: Read + Write + Seek>(
    output: &mut W,
    current_len: &mut u64,
    address: u32,
    data: &[u8],
    pad: u8,
    max_len: u64,
) -> Result<()> {
    if data.is_empty() {
        return Ok(());
    }
    let start = u64::from(address);
    let end = start + data.len() as u64;
    if end > max_len {
        return Err(Error::Format(
            "image address exceeds selected chip capacity".into(),
        ));
    }
    if end > *current_len {
        output.seek(SeekFrom::Start(*current_len))?;
        let fill = [pad; CHUNK_BYTES];
        let mut remaining = end - *current_len;
        while remaining > 0 {
            let count = remaining.min(CHUNK_BYTES as u64) as usize;
            output.write_all(&fill[..count])?;
            remaining -= count as u64;
        }
        *current_len = end;
    }
    output.seek(SeekFrom::Start(start))?;
    output.write_all(data)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device::Image;
    use std::io::{BufReader, Cursor};

    #[derive(Default)]
    struct CountingSpool {
        position: u64,
        length: u64,
        largest_write: usize,
        last_byte: u8,
    }

    impl Read for CountingSpool {
        fn read(&mut self, _bytes: &mut [u8]) -> std::io::Result<usize> {
            Ok(0)
        }
    }

    impl Seek for CountingSpool {
        fn seek(&mut self, from: SeekFrom) -> std::io::Result<u64> {
            let position = match from {
                SeekFrom::Start(value) => i128::from(value),
                SeekFrom::End(value) => i128::from(self.length) + i128::from(value),
                SeekFrom::Current(value) => i128::from(self.position) + i128::from(value),
            };
            self.position = u64::try_from(position).map_err(|_| {
                std::io::Error::new(std::io::ErrorKind::InvalidInput, "invalid seek")
            })?;
            Ok(self.position)
        }
    }

    impl Write for CountingSpool {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.largest_write = self.largest_write.max(bytes.len());
            self.position += bytes.len() as u64;
            if self.position >= self.length {
                self.length = self.position;
                if let Some(value) = bytes.last() {
                    self.last_byte = *value;
                }
            }
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn addressed_image_beyond_256_mib_is_spooled_in_bounded_chunks() {
        let mut source = String::new();
        ihex_record(&mut source, &[2, 0, 0, 4, 0x10, 0]);
        ihex_record(&mut source, &[1, 0, 0, 0, 0x55]);
        ihex_record(&mut source, &[0, 0, 0, 1]);
        let mut spool = CountingSpool::default();
        let bytes = Format::IHex
            .decode_to(
                &mut Cursor::new(source),
                &mut spool,
                0xff,
                MAX_STREAMED_IMAGE_BYTES,
            )
            .unwrap();
        assert_eq!(bytes, 256 * 1024 * 1024 + 1);
        assert_eq!(spool.length, bytes);
        assert_eq!(spool.last_byte, 0x55);
        assert!(spool.largest_write <= 64 * 1024);
    }

    #[test]
    fn streamed_formats_match_existing_wire_files_across_address_boundaries() {
        let image = Image {
            bytes: (0..70_003).map(|index| (index % 251) as u8).collect(),
        };
        for format in [Format::Raw, Format::IHex, Format::SRec] {
            let mut encoded = Vec::new();
            format
                .encode_from(
                    &mut Cursor::new(&image.bytes),
                    &mut encoded,
                    image.len() as u64,
                )
                .unwrap();
            assert_eq!(encoded, format.emit(&image));
            let mut decoded = Cursor::new(Vec::new());
            let len = format
                .decode_to(
                    &mut BufReader::with_capacity(7, Cursor::new(encoded)),
                    &mut decoded,
                    0xff,
                    MAX_STREAMED_IMAGE_BYTES,
                )
                .unwrap();
            assert_eq!(len, image.len() as u64);
            assert_eq!(decoded.into_inner(), image.bytes);
        }
    }

    #[test]
    fn stream_rejects_corruption_and_oversized_records_before_publication() {
        for bytes in [b":0100000012FF\n".as_slice(), b"S10400001200\n".as_slice()] {
            let format = if bytes[0] == b':' {
                Format::IHex
            } else {
                Format::SRec
            };
            let mut output = Cursor::new(Vec::new());
            assert!(format
                .decode_to(&mut Cursor::new(bytes), &mut output, 0xff, 128)
                .is_err());
            assert!(output.into_inner().is_empty());
        }
        let mut output = Cursor::new(Vec::new());
        assert!(Format::IHex
            .decode_to(&mut Cursor::new(vec![b' '; 10_000]), &mut output, 0xff, 128)
            .is_err());
        assert!(output.into_inner().is_empty());
    }

    #[test]
    fn stream_honors_capacity_and_requires_a_private_empty_spool() {
        let mut output = Cursor::new(Vec::new());
        assert!(Format::Raw
            .decode_to(&mut Cursor::new([1, 2, 3]), &mut output, 0xff, 2)
            .is_err());
        let mut existing = Cursor::new(vec![0xaa]);
        assert!(Format::Raw
            .decode_to(&mut Cursor::new([1]), &mut existing, 0xff, 2)
            .is_err());
        assert_eq!(existing.into_inner(), vec![0xaa]);
        assert!(Format::Raw
            .encode_from(&mut Cursor::new([1, 2]), &mut Vec::new(), 3)
            .is_err());
    }

    #[test]
    fn addressed_gaps_and_overlapping_records_match_the_memory_parser() {
        let mut records = String::new();
        ihex_record(&mut records, &[2, 0, 8, 0, 0xaa, 0xbb]);
        ihex_record(&mut records, &[1, 0, 8, 0, 0xcc]);
        ihex_record(&mut records, &[0, 0, 0, 1]);
        let mut spool = Cursor::new(Vec::new());
        Format::IHex
            .decode_to(&mut Cursor::new(records.as_bytes()), &mut spool, 0xe5, 16)
            .unwrap();
        assert_eq!(
            spool.into_inner(),
            Format::IHex.parse(records.as_bytes(), 0xe5).unwrap().bytes
        );
    }
}
