// SPDX-License-Identifier: MIT
//! Private disk-backed images. The source file is never opened for writing.
//! Only pages, codec records, and 64 KiB I/O chunks enter memory.

use minipro_core::format::{Format, PAD};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::fs::{self, File};
use std::io::{self, BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::ops::Range;
use std::path::{Path, PathBuf};
use tempfile::{NamedTempFile, TempDir};

const MAX_BYTES: u64 = 2 * 1024 * 1024 * 1024;
const CHUNK_BYTES: usize = 64 * 1024;
const HISTORY_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const HISTORY_EDITS: usize = 128;

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BufferRequest {
    pub operation: String,
    pub file: Option<String>,
    pub offset: Option<u64>,
    pub count: Option<u64>,
    pub start: Option<u64>,
    pub end: Option<u64>,
    pub destination: Option<u64>,
    pub value: Option<u64>,
    pub query: Option<String>,
    pub origin_chip: Option<String>,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BufferReply {
    pub size: u64,
    pub offset: u64,
    pub bytes: Vec<u8>,
    pub sha256: String,
    pub dirty: bool,
    pub can_undo: bool,
    pub can_redo: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin_chip: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub found_offset: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_mismatch: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub other_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub matches: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub saved_path: Option<String>,
}

enum Replacement {
    Fill(u8),
    File(NamedTempFile),
}

struct Edit {
    range: Range<u64>,
    previous: NamedTempFile,
    replacement: Replacement,
}

impl Edit {
    fn stored_bytes(&self) -> u64 {
        (self.range.end - self.range.start)
            * if matches!(&self.replacement, Replacement::File(_)) {
                2
            } else {
                1
            }
    }
}

struct Loaded {
    // Keep the directory alive until the image and history handles are gone.
    image: NamedTempFile,
    undo: VecDeque<Edit>,
    redo: Vec<Edit>,
    directory: TempDir,
    size: u64,
    source: PathBuf,
    source_entry: PathBuf,
    source_canonical: PathBuf,
    origin_chip: Option<String>,
    hash: Option<String>,
    saved_hash: String,
    // A failed rollback is never exposed as a valid image.
    fault: Option<String>,
}

#[derive(Default)]
pub struct HexBuffer {
    loaded: Option<Loaded>,
}

impl HexBuffer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Remains available when an operation's reply cannot be read or hashed.
    /// A successful mutation invalidates the hash before reply construction;
    /// until rehashed, native close must conservatively protect those bytes.
    pub fn is_dirty(&self) -> bool {
        self.loaded.as_ref().is_some_and(|image| {
            image.fault.is_some()
                || image
                    .hash
                    .as_ref()
                    .is_none_or(|hash| hash != &image.saved_hash)
        })
    }

    pub fn execute(&mut self, request: BufferRequest) -> Result<BufferReply, String> {
        // Validate paging before any edit or open can change the working state.
        if request
            .count
            .is_some_and(|count| count > CHUNK_BYTES as u64)
        {
            return Err(invalid_range());
        }
        if request.operation == "open" {
            let path = required_path(request.file.as_deref())?;
            // Construct and hash the replacement completely before dropping the
            // current image, including on malformed input or disk exhaustion.
            let next = Loaded::open(path, request.origin_chip)?;
            self.loaded = Some(next);
            return self
                .loaded
                .as_mut()
                .expect("loaded above")
                .reply(Some((0, request.count.unwrap_or(256))));
        }
        if request.operation == "state" && self.loaded.is_none() {
            return Ok(BufferReply::default());
        }
        let image = self
            .loaded
            .as_mut()
            .ok_or_else(|| "Open an image in the Hex Editor first.".to_string())?;
        if let Some(fault) = &image.fault {
            return Err(format!("The working image is unavailable after an I/O failure. Reopen the source file. {fault}"));
        }
        let mut page = None;
        let mut found = None;
        let mut compared = None;
        let mut saved = None;
        match request.operation.as_str() {
            "page" => page = Some((request.offset.unwrap_or(0), request.count.unwrap_or(256))),
            "state" => {}
            "edit" => {
                let offset = required(request.offset, "offset")?;
                let value = byte_value(request.value)?;
                let range = image.checked_range(offset, offset)?;
                image.apply(range, Replacement::Fill(value))?;
                page = Some((offset, request.count.unwrap_or(256)));
            }
            "fill" => {
                let start = required(request.start, "start")?;
                let range = image.checked_range(start, required(request.end, "end")?)?;
                image.apply(range, Replacement::Fill(byte_value(request.value)?))?;
                page = Some((start, request.count.unwrap_or(256)));
            }
            "copy" => {
                let range = image.checked_range(
                    required(request.start, "start")?,
                    required(request.end, "end")?,
                )?;
                let count = range.end - range.start;
                let destination = required(request.destination, "destination")?;
                if destination > image.size - count {
                    return Err(invalid_range());
                }
                let snapshot = image.snapshot(range)?;
                image.apply(
                    destination..destination + count,
                    Replacement::File(snapshot),
                )?;
                page = Some((destination, request.count.unwrap_or(256)));
            }
            "undo" => {
                if let Some(range) = image.undo()? {
                    page = Some((range.start, request.count.unwrap_or(256)));
                }
            }
            "redo" => {
                if let Some(range) = image.redo()? {
                    page = Some((range.start, request.count.unwrap_or(256)));
                }
            }
            "find_hex" | "find_ascii" => {
                let query = request.query.as_deref().unwrap_or_default();
                let needle = if request.operation == "find_hex" {
                    parse_hex(query)?
                } else {
                    if !query.is_ascii() {
                        return Err("ASCII search accepts ASCII characters only.".into());
                    }
                    if query.len() > 256 {
                        return Err("Search is limited to 256 bytes.".into());
                    }
                    query.as_bytes().to_vec()
                };
                found = image.find(&needle, request.offset.unwrap_or(0))?;
            }
            "compare" => compared = Some(image.compare(required_path(request.file.as_deref())?)?),
            "save" => {
                let path = required_path(request.file.as_deref())?;
                image.export(0..image.size, path)?;
                image.saved_hash = image.sha256()?;
                saved = Some(path.to_string_lossy().into_owned());
            }
            "export" => {
                let range = image.checked_range(
                    required(request.start, "start")?,
                    required(request.end, "end")?,
                )?;
                let path = required_path(request.file.as_deref())?;
                image.export(range, path)?;
                saved = Some(path.to_string_lossy().into_owned());
            }
            _ => return Err("Unknown buffer operation.".into()),
        }
        let mut reply = image.reply(page)?;
        reply.found_offset = found;
        if let Some((mismatch, size)) = compared {
            reply.first_mismatch = mismatch;
            reply.other_bytes = Some(size);
            reply.matches = Some(mismatch.is_none());
        }
        reply.saved_path = saved;
        Ok(reply)
    }
}

impl Loaded {
    fn open(source: &Path, origin_chip: Option<String>) -> Result<Self, String> {
        let source_entry = resolved_entry(source).map_err(io_error)?;
        let source_canonical = fs::canonicalize(source).map_err(io_error)?;
        let directory = tempfile::Builder::new()
            .prefix("xgecu-buffer-")
            .tempdir()
            .map_err(io_error)?;
        let mut image = private_file(directory.path())?;
        let size = decode(source, image.as_file_mut(), false)?;
        image.as_file().sync_all().map_err(io_error)?;
        let mut result = Self {
            image,
            directory,
            undo: VecDeque::new(),
            redo: Vec::new(),
            size,
            source: source.to_path_buf(),
            source_entry,
            source_canonical,
            origin_chip,
            hash: None,
            saved_hash: String::new(),
            fault: None,
        };
        result.saved_hash = result.sha256()?;
        Ok(result)
    }

    fn reply(&mut self, page: Option<(u64, u64)>) -> Result<BufferReply, String> {
        let (offset, bytes) = match page {
            Some((offset, count)) => (offset, self.page(offset, count)?),
            None => (0, Vec::new()),
        };
        let sha256 = self.sha256()?;
        Ok(BufferReply {
            size: self.size,
            offset,
            bytes,
            dirty: sha256 != self.saved_hash,
            sha256,
            can_undo: !self.undo.is_empty(),
            can_redo: !self.redo.is_empty(),
            source: Some(self.source.to_string_lossy().into_owned()),
            origin_chip: self.origin_chip.clone(),
            ..BufferReply::default()
        })
    }

    fn page(&mut self, offset: u64, count: u64) -> Result<Vec<u8>, String> {
        if offset > self.size || count > CHUNK_BYTES as u64 {
            return Err(invalid_range());
        }
        let count = count.min(self.size - offset) as usize;
        self.image
            .as_file_mut()
            .seek(SeekFrom::Start(offset))
            .map_err(io_error)?;
        let mut bytes = vec![0; count];
        self.image
            .as_file_mut()
            .read_exact(&mut bytes)
            .map_err(io_error)?;
        Ok(bytes)
    }

    fn sha256(&mut self) -> Result<String, String> {
        if let Some(hash) = &self.hash {
            return Ok(hash.clone());
        }
        let input = self.image.as_file_mut();
        input.seek(SeekFrom::Start(0)).map_err(io_error)?;
        let mut hash = Sha256::new();
        let mut chunk = [0u8; CHUNK_BYTES];
        let mut remaining = self.size;
        while remaining > 0 {
            let n = remaining.min(CHUNK_BYTES as u64) as usize;
            input.read_exact(&mut chunk[..n]).map_err(io_error)?;
            hash.update(&chunk[..n]);
            remaining -= n as u64;
        }
        let hash: String = hash
            .finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        self.hash = Some(hash.clone());
        Ok(hash)
    }

    fn checked_range(&self, start: u64, end: u64) -> Result<Range<u64>, String> {
        if start > end || end >= self.size {
            return Err(invalid_range());
        }
        Ok(start..end + 1)
    }

    fn snapshot(&mut self, range: Range<u64>) -> Result<NamedTempFile, String> {
        let mut output = private_file(self.directory.path())?;
        copy_range(self.image.as_file_mut(), range, output.as_file_mut()).map_err(io_error)?;
        output.as_file_mut().flush().map_err(io_error)?;
        Ok(output)
    }

    fn replace(&mut self, range: Range<u64>, replacement: &mut Replacement) -> io::Result<()> {
        let output = self.image.as_file_mut();
        output.seek(SeekFrom::Start(range.start))?;
        match replacement {
            Replacement::Fill(value) => {
                let chunk = [*value; CHUNK_BYTES];
                let mut remaining = range.end - range.start;
                while remaining > 0 {
                    let n = remaining.min(CHUNK_BYTES as u64) as usize;
                    output.write_all(&chunk[..n])?;
                    remaining -= n as u64;
                }
            }
            Replacement::File(input) => {
                copy_range(input.as_file_mut(), 0..range.end - range.start, output)?
            }
        }
        output.flush()
    }

    fn restore_after_error(
        &mut self,
        range: Range<u64>,
        previous: &mut Replacement,
        error: io::Error,
    ) -> String {
        match self.replace(range, previous) {
            Ok(()) => io_error(error),
            Err(rollback) => {
                let message = format!("{} Rollback also failed: {}", io_error(error), rollback);
                self.hash = None;
                self.fault = Some(message.clone());
                message
            }
        }
    }

    fn apply(&mut self, range: Range<u64>, mut replacement: Replacement) -> Result<(), String> {
        let previous = self.snapshot(range.clone())?;
        if let Err(error) = self.replace(range.clone(), &mut replacement) {
            let mut rollback = Replacement::File(previous);
            return Err(self.restore_after_error(range, &mut rollback, error));
        }
        // The old data remains on disk until the new operation succeeds.
        self.undo.push_back(Edit {
            range,
            previous,
            replacement,
        });
        self.redo.clear();
        self.hash = None;
        self.trim_history();
        Ok(())
    }

    fn undo(&mut self) -> Result<Option<Range<u64>>, String> {
        let Some(mut edit) = self.undo.pop_back() else {
            return Ok(None);
        };
        let range = edit.range.clone();
        let result = copy_into_range(
            edit.previous.as_file_mut(),
            self.image.as_file_mut(),
            range.clone(),
        );
        if let Err(error) = result {
            let message = self.restore_after_error(range, &mut edit.replacement, error);
            self.undo.push_back(edit);
            return Err(message);
        }
        self.redo.push(edit);
        self.hash = None;
        Ok(Some(range))
    }

    fn redo(&mut self) -> Result<Option<Range<u64>>, String> {
        let Some(mut edit) = self.redo.pop() else {
            return Ok(None);
        };
        let range = edit.range.clone();
        if let Err(error) = self.replace(range.clone(), &mut edit.replacement) {
            let rollback =
                copy_into_range(edit.previous.as_file_mut(), self.image.as_file_mut(), range);
            let message = match rollback {
                Ok(()) => io_error(error),
                Err(rollback) => {
                    let message = format!("{} Rollback also failed: {}", io_error(error), rollback);
                    self.fault = Some(message.clone());
                    self.hash = None;
                    message
                }
            };
            self.redo.push(edit);
            return Err(message);
        }
        self.undo.push_back(edit);
        self.hash = None;
        Ok(Some(range))
    }

    fn trim_history(&mut self) {
        let mut bytes: u64 = self.undo.iter().map(Edit::stored_bytes).sum();
        while self.undo.len() > HISTORY_EDITS || bytes > HISTORY_BYTES {
            if let Some(edit) = self.undo.pop_front() {
                bytes -= edit.stored_bytes();
            } else {
                break;
            }
        }
    }

    fn find(&mut self, needle: &[u8], start: u64) -> Result<Option<u64>, String> {
        if needle.is_empty() || needle.len() > 256 || start > self.size {
            return Ok(None);
        }
        // Streaming KMP retains a 256-entry prefix table, never a growing
        // overlap window. A wrapped match may cross the search-start boundary.
        let mut prefix = [0usize; 256];
        let mut matched = 0;
        for i in 1..needle.len() {
            while matched > 0 && needle[i] != needle[matched] {
                matched = prefix[matched - 1];
            }
            if needle[i] == needle[matched] {
                matched += 1;
            }
            prefix[i] = matched;
        }
        for (lower, upper) in [(start, self.size), (0, start)] {
            if lower == upper {
                continue;
            }
            let end = self.size.min(upper.saturating_add(needle.len() as u64 - 1));
            let input = self.image.as_file_mut();
            input.seek(SeekFrom::Start(lower)).map_err(io_error)?;
            let mut offset = lower;
            let mut matched = 0;
            let mut chunk = [0u8; CHUNK_BYTES];
            while offset < end {
                let n = (end - offset).min(CHUNK_BYTES as u64) as usize;
                input.read_exact(&mut chunk[..n]).map_err(io_error)?;
                for (i, byte) in chunk[..n].iter().enumerate() {
                    while matched > 0 && *byte != needle[matched] {
                        matched = prefix[matched - 1];
                    }
                    if *byte == needle[matched] {
                        matched += 1;
                    }
                    if matched == needle.len() {
                        let found = offset + i as u64 + 1 - needle.len() as u64;
                        if found < upper {
                            return Ok(Some(found));
                        }
                        matched = prefix[matched - 1];
                    }
                }
                offset += n as u64;
            }
        }
        Ok(None)
    }

    fn compare(&mut self, source: &Path) -> Result<(Option<u64>, u64), String> {
        let mut other = private_file(self.directory.path())?;
        let size = decode(source, other.as_file_mut(), true)?;
        let common = size.min(self.size);
        let left = self.image.as_file_mut();
        let right = other.as_file_mut();
        left.seek(SeekFrom::Start(0)).map_err(io_error)?;
        right.seek(SeekFrom::Start(0)).map_err(io_error)?;
        let mut a = [0u8; CHUNK_BYTES];
        let mut b = [0u8; CHUNK_BYTES];
        let mut offset = 0;
        while offset < common {
            let n = (common - offset).min(CHUNK_BYTES as u64) as usize;
            left.read_exact(&mut a[..n]).map_err(io_error)?;
            right.read_exact(&mut b[..n]).map_err(io_error)?;
            if let Some(i) = a[..n].iter().zip(&b[..n]).position(|(a, b)| a != b) {
                return Ok((Some(offset + i as u64), size));
            }
            offset += n as u64;
        }
        Ok(((size != self.size).then_some(common), size))
    }

    fn export(&mut self, range: Range<u64>, destination: &Path) -> Result<(), String> {
        let entry = resolved_entry(destination).map_err(io_error)?;
        let is_symlink = fs::symlink_metadata(destination)
            .map(|metadata| metadata.file_type().is_symlink())
            .unwrap_or(false);
        if entry == self.source_entry
            || (!is_symlink
                && fs::canonicalize(destination).ok().as_ref() == Some(&self.source_canonical))
        {
            return Err("Choose another file: the original image is preserved unchanged.".into());
        }
        let parent = entry
            .parent()
            .ok_or_else(|| "The output path has no parent directory.".to_string())?;
        let mut output = private_file(parent)?;
        let size = range.end - range.start;
        let format = Format::from_path(destination);
        if format == Format::Raw {
            copy_range(self.image.as_file_mut(), range, output.as_file_mut()).map_err(io_error)?;
        } else {
            // Codecs require an exact-length seekable spool. A private range
            // snapshot also keeps export address zero relative to the block.
            let mut snapshot = self.snapshot(range)?;
            let mut writer = BufWriter::with_capacity(CHUNK_BYTES, output.as_file_mut());
            format
                .encode_from(snapshot.as_file_mut(), &mut writer, size)
                .map_err(|error| error.to_string())?;
            writer.flush().map_err(io_error)?;
        }
        output.as_file_mut().sync_all().map_err(io_error)?;
        // tempfile::persist uses atomic replacement on supported platforms.
        // It replaces the destination directory entry, including a symlink,
        // without opening or truncating the destination's target.
        output
            .persist(&entry)
            .map_err(|error| io_error(error.error))?;
        Ok(())
    }
}

fn decode(source: &Path, output: &mut File, allow_empty: bool) -> Result<u64, String> {
    let file = File::open(source).map_err(io_error)?;
    if !file.metadata().map_err(io_error)?.is_file() {
        return Err("Choose a regular image file.".into());
    }
    let mut input = BufReader::with_capacity(CHUNK_BYTES, file);
    let extension = Format::from_path(source);
    // Known binary extensions are byte-exact, just as policy::input_format
    // forces --format raw for programming. Valid-looking text records can be
    // legitimate binary content and must not change what the editor displays.
    let explicit_raw = source
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            ["bin", "rom", "raw"]
                .iter()
                .any(|candidate| extension.eq_ignore_ascii_case(candidate))
        });
    let format = if explicit_raw {
        Format::Raw
    } else if extension == Format::Raw {
        Format::detect_from(&mut input).map_err(|error| error.to_string())?
    } else {
        extension
    };
    if format == Format::Raw && input.get_ref().metadata().map_err(io_error)?.len() > MAX_BYTES {
        return Err(invalid_size());
    }
    let size = format
        .decode_to(&mut input, output, PAD, MAX_BYTES)
        .map_err(|error| error.to_string())?;
    if (!allow_empty && size == 0) || size > MAX_BYTES {
        return Err(invalid_size());
    }
    Ok(size)
}

fn copy_range(input: &mut File, range: Range<u64>, output: &mut File) -> io::Result<()> {
    input.seek(SeekFrom::Start(range.start))?;
    let mut remaining = range.end - range.start;
    let mut chunk = [0u8; CHUNK_BYTES];
    while remaining > 0 {
        let n = remaining.min(CHUNK_BYTES as u64) as usize;
        input.read_exact(&mut chunk[..n])?;
        output.write_all(&chunk[..n])?;
        remaining -= n as u64;
    }
    Ok(())
}

fn copy_into_range(input: &mut File, output: &mut File, range: Range<u64>) -> io::Result<()> {
    output.seek(SeekFrom::Start(range.start))?;
    copy_range(input, 0..range.end - range.start, output)?;
    output.flush()
}

fn private_file(directory: &Path) -> Result<NamedTempFile, String> {
    tempfile::Builder::new()
        .prefix(".xgecu-")
        .tempfile_in(directory)
        .map_err(io_error)
}

// Resolve the parent but preserve the final component, which must be replaced
// atomically instead of following a possibly existing destination symlink.
fn resolved_entry(path: &Path) -> io::Result<PathBuf> {
    let name = path.file_name().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "The file path has no filename.",
        )
    })?;
    let parent = path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    Ok(fs::canonicalize(parent)?.join(name))
}

fn required_path(path: Option<&str>) -> Result<&Path, String> {
    path.filter(|path| !path.is_empty())
        .map(Path::new)
        .ok_or_else(|| "Choose an image file.".into())
}

fn required(value: Option<u64>, field: &str) -> Result<u64, String> {
    value.ok_or_else(|| format!("Missing {field}."))
}

fn byte_value(value: Option<u64>) -> Result<u8, String> {
    u8::try_from(required(value, "value")?)
        .map_err(|_| "The byte value must be between 0 and 255.".into())
}

fn parse_hex(query: &str) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::with_capacity(256);
    let mut high = None;
    for byte in query.bytes().filter(|byte| !byte.is_ascii_whitespace()) {
        let digit = match byte {
            b'0'..=b'9' => byte - b'0',
            b'a'..=b'f' => byte - b'a' + 10,
            b'A'..=b'F' => byte - b'A' + 10,
            _ => {
                return Err(
                    "Enter pairs of hexadecimal digits, optionally separated by spaces.".into(),
                )
            }
        };
        if let Some(first) = high.take() {
            if bytes.len() == 256 {
                return Err("Search is limited to 256 bytes.".into());
            }
            bytes.push(first * 16 + digit);
        } else {
            high = Some(digit);
        }
    }
    if high.is_some() {
        return Err("Enter complete pairs of hexadecimal digits.".into());
    }
    Ok(bytes)
}

fn invalid_range() -> String {
    "The address range is outside the buffer or exceeds the 64 KiB page limit.".into()
}
fn invalid_size() -> String {
    "The image must be between 1 byte and 2 GiB.".into()
}
fn io_error(error: io::Error) -> String {
    format!("Image I/O failed: {error}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(operation: &str) -> BufferRequest {
        BufferRequest {
            operation: operation.into(),
            ..BufferRequest::default()
        }
    }

    fn load(bytes: &[u8]) -> (TempDir, HexBuffer, PathBuf) {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("original.bin");
        fs::write(&source, bytes).unwrap();
        let mut buffer = HexBuffer::new();
        buffer
            .execute(BufferRequest {
                file: Some(source.to_str().unwrap().into()),
                ..request("open")
            })
            .unwrap();
        (directory, buffer, source)
    }

    fn bytes(buffer: &mut HexBuffer) -> Vec<u8> {
        buffer
            .execute(BufferRequest {
                count: Some(CHUNK_BYTES as u64),
                ..request("page")
            })
            .unwrap()
            .bytes
    }

    #[test]
    fn inclusive_fill_undo_redo_dirty_and_original_preservation() {
        let (_directory, mut buffer, source) = load(&[0x10, 0x20, 0x30, 0x40]);
        let filled = buffer
            .execute(BufferRequest {
                start: Some(0),
                end: Some(3),
                value: Some(255),
                ..request("fill")
            })
            .unwrap();
        assert_eq!(filled.bytes, [255; 4]);
        assert!(filled.dirty && filled.can_undo && !filled.can_redo);
        let undo = buffer.execute(request("undo")).unwrap();
        assert_eq!(undo.bytes, [0x10, 0x20, 0x30, 0x40]);
        assert!(!undo.dirty && undo.can_redo);
        assert_eq!(buffer.execute(request("redo")).unwrap().bytes, [255; 4]);
        assert_eq!(fs::read(source).unwrap(), [0x10, 0x20, 0x30, 0x40]);
    }

    #[test]
    fn byte_edit_and_new_edit_clears_redo() {
        let (_directory, mut buffer, _) = load(&[0, 1, 2]);
        buffer
            .execute(BufferRequest {
                offset: Some(2),
                value: Some(0xab),
                ..request("edit")
            })
            .unwrap();
        assert_eq!(bytes(&mut buffer), [0, 1, 0xab]);
        buffer.execute(request("undo")).unwrap();
        let edited = buffer
            .execute(BufferRequest {
                offset: Some(0),
                value: Some(0xcd),
                ..request("edit")
            })
            .unwrap();
        assert!(!edited.can_redo);
        assert_eq!(bytes(&mut buffer), [0xcd, 1, 2]);
        assert!(buffer
            .execute(BufferRequest {
                offset: Some(3),
                value: Some(0),
                ..request("edit")
            })
            .is_err());
        assert!(buffer
            .execute(BufferRequest {
                offset: Some(0),
                value: Some(256),
                ..request("edit")
            })
            .is_err());
    }

    #[test]
    fn invalid_ranges_or_reply_count_never_mutate_state() {
        let (_directory, mut buffer, _) = load(&[0x12, 0x34]);
        for (start, end) in [(1, 0), (0, 2), (u64::MAX, u64::MAX)] {
            assert!(buffer
                .execute(BufferRequest {
                    start: Some(start),
                    end: Some(end),
                    value: Some(255),
                    ..request("fill")
                })
                .is_err());
        }
        assert!(buffer
            .execute(BufferRequest {
                offset: Some(0),
                value: Some(255),
                count: Some(CHUNK_BYTES as u64 + 1),
                ..request("edit")
            })
            .is_err());
        assert_eq!(bytes(&mut buffer), [0x12, 0x34]);
        assert!(!buffer.execute(request("state")).unwrap().can_undo);
        assert!(buffer
            .execute(BufferRequest {
                offset: Some(3),
                ..request("page")
            })
            .is_err());
        assert!(buffer
            .execute(BufferRequest {
                offset: Some(2),
                ..request("page")
            })
            .unwrap()
            .bytes
            .is_empty());
    }

    #[test]
    fn overlapping_copy_snapshots_source_and_is_undoable() {
        let (_directory, mut buffer, _) = load(&[1, 2, 3, 4, 5]);
        buffer
            .execute(BufferRequest {
                start: Some(0),
                end: Some(2),
                destination: Some(1),
                ..request("copy")
            })
            .unwrap();
        assert_eq!(bytes(&mut buffer), [1, 1, 2, 3, 5]);
        buffer.execute(request("undo")).unwrap();
        assert_eq!(bytes(&mut buffer), [1, 2, 3, 4, 5]);
        buffer.execute(request("redo")).unwrap();
        assert_eq!(bytes(&mut buffer), [1, 1, 2, 3, 5]);
        assert!(buffer
            .execute(BufferRequest {
                start: Some(0),
                end: Some(2),
                destination: Some(3),
                ..request("copy")
            })
            .is_err());
    }

    #[test]
    fn search_wraps_across_io_chunk_and_search_start_boundaries() {
        let mut data = vec![0; 65_540];
        data[65_535..65_539].copy_from_slice(b"ABCD");
        let (_directory, mut buffer, _) = load(&data);
        for offset in [0, 65_535, 65_537, 65_540] {
            let found = buffer
                .execute(BufferRequest {
                    query: Some("ABCD".into()),
                    offset: Some(offset),
                    ..request("find_ascii")
                })
                .unwrap();
            assert_eq!(found.found_offset, Some(65_535));
        }
        assert_eq!(
            buffer
                .execute(BufferRequest {
                    query: Some("41 42\t43 44".into()),
                    ..request("find_hex")
                })
                .unwrap()
                .found_offset,
            Some(65_535)
        );
        assert_eq!(
            buffer
                .execute(BufferRequest {
                    query: Some("missing".into()),
                    ..request("find_ascii")
                })
                .unwrap()
                .found_offset,
            None
        );
        assert_eq!(
            buffer
                .execute(BufferRequest {
                    query: Some(String::new()),
                    ..request("find_ascii")
                })
                .unwrap()
                .found_offset,
            None
        );
        assert!(buffer
            .execute(BufferRequest {
                query: Some("abc".into()),
                ..request("find_hex")
            })
            .is_err());
        assert!(buffer
            .execute(BufferRequest {
                query: Some("gg".into()),
                ..request("find_hex")
            })
            .is_err());
        assert!(buffer
            .execute(BufferRequest {
                query: Some("a".repeat(257)),
                ..request("find_ascii")
            })
            .is_err());
        assert!(buffer
            .execute(BufferRequest {
                query: Some("é".into()),
                ..request("find_ascii")
            })
            .is_err());
    }

    #[test]
    fn sha_and_compare_detect_bytes_lengths_and_empty_images() {
        let (directory, mut buffer, _) = load(b"abc");
        assert_eq!(
            buffer.execute(request("state")).unwrap().sha256,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        let other = directory.path().join("other.bin");
        for (content, first, matches) in [
            (b"abc".as_slice(), None, true),
            (b"abd", Some(2), false),
            (b"ab", Some(2), false),
            (b"abcd", Some(3), false),
            (b"", Some(0), false),
        ] {
            fs::write(&other, content).unwrap();
            let result = buffer
                .execute(BufferRequest {
                    file: Some(other.to_str().unwrap().into()),
                    ..request("compare")
                })
                .unwrap();
            assert_eq!(result.first_mismatch, first);
            assert_eq!(result.other_bytes, Some(content.len() as u64));
            assert_eq!(result.matches, Some(matches));
        }
    }

    #[test]
    fn unicode_save_export_and_atomic_original_guard() {
        let (directory, mut buffer, source) = load(&[0x10, 0x20, 0x30, 0x40]);
        buffer
            .execute(BufferRequest {
                offset: Some(0),
                value: Some(0xab),
                ..request("edit")
            })
            .unwrap();
        assert!(buffer
            .execute(BufferRequest {
                file: Some(source.to_str().unwrap().into()),
                ..request("save")
            })
            .is_err());
        let output = directory.path().join("прошивка Ελληνικά 中文.bin");
        fs::write(&output, [9, 9, 9]).unwrap();
        let saved = buffer
            .execute(BufferRequest {
                file: Some(output.to_str().unwrap().into()),
                ..request("save")
            })
            .unwrap();
        assert!(!saved.dirty);
        assert_eq!(fs::read(&output).unwrap(), [0xab, 0x20, 0x30, 0x40]);
        assert_eq!(fs::read(&source).unwrap(), [0x10, 0x20, 0x30, 0x40]);
        let block = directory.path().join("block.bin");
        buffer
            .execute(BufferRequest {
                file: Some(block.to_str().unwrap().into()),
                start: Some(1),
                end: Some(2),
                ..request("export")
            })
            .unwrap();
        assert_eq!(fs::read(&block).unwrap(), [0x20, 0x30]);
        assert!(buffer
            .execute(BufferRequest {
                file: Some(block.to_str().unwrap().into()),
                start: Some(1),
                end: Some(4),
                ..request("export")
            })
            .is_err());
        assert_eq!(fs::read(&block).unwrap(), [0x20, 0x30]);
    }

    #[cfg(unix)]
    #[test]
    fn atomic_export_replaces_symlink_without_touching_target_or_source() {
        use std::os::unix::fs::symlink;
        let (directory, mut buffer, source) = load(&[0x10, 0x20, 0x30]);
        let target = directory.path().join("target.bin");
        fs::write(&target, [0xab]).unwrap();
        let link = directory.path().join("link.bin");
        symlink(&target, &link).unwrap();
        buffer.loaded.as_mut().unwrap().export(1..3, &link).unwrap();
        assert!(!fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink());
        assert_eq!(fs::read(&link).unwrap(), [0x20, 0x30]);
        assert_eq!(fs::read(&target).unwrap(), [0xab]);
        fs::remove_file(&link).unwrap();
        symlink(&source, &link).unwrap();
        buffer.loaded.as_mut().unwrap().export(1..3, &link).unwrap();
        assert_eq!(fs::read(&source).unwrap(), [0x10, 0x20, 0x30]);
    }

    #[cfg(unix)]
    #[test]
    fn internal_paths_preserve_non_utf8_filenames() {
        use std::os::unix::ffi::OsStringExt;
        let directory = tempfile::tempdir().unwrap();
        let source = directory
            .path()
            .join(std::ffi::OsString::from_vec(b"source-\xff.bin".to_vec()));
        let output = directory
            .path()
            .join(std::ffi::OsString::from_vec(b"saved-\xfe.bin".to_vec()));
        fs::write(&source, [1, 2, 3]).unwrap();
        let mut image = Loaded::open(&source, None).unwrap();
        image.export(0..3, &output).unwrap();
        assert_eq!(fs::read(output).unwrap(), [1, 2, 3]);
    }

    #[test]
    fn streaming_formats_roundtrip_export_ranges_and_compare_decoded_data() {
        let data: Vec<u8> = (0..70_003).map(|i| (i % 251) as u8).collect();
        let (directory, mut buffer, _) = load(&data);
        for extension in ["hex", "srec"] {
            let output = directory.path().join(format!("image.{extension}"));
            buffer
                .loaded
                .as_mut()
                .unwrap()
                .export(0..data.len() as u64, &output)
                .unwrap();
            let compared = buffer.loaded.as_mut().unwrap().compare(&output).unwrap();
            assert_eq!(compared, (None, data.len() as u64));
            let mut imported = Loaded::open(&output, None).unwrap();
            assert_eq!(
                imported.sha256().unwrap(),
                buffer.loaded.as_mut().unwrap().sha256().unwrap()
            );
            let block = directory.path().join(format!("block.{extension}"));
            buffer
                .loaded
                .as_mut()
                .unwrap()
                .export(65_530..65_540, &block)
                .unwrap();
            let mut decoded = Loaded::open(&block, None).unwrap();
            assert_eq!(decoded.page(0, 20).unwrap(), data[65_530..65_540]);
        }
    }

    #[test]
    fn explicit_binary_extensions_preserve_valid_text_record_bytes() {
        let directory = tempfile::tempdir().unwrap();
        let content = b":03000000010203F7\n:00000001FF\n";
        for extension in ["bin", "BIN", "rom", "RoM", "raw", "RAW"] {
            let source = directory.path().join(format!("source.{extension}"));
            let output = directory.path().join(format!("saved.{extension}"));
            fs::write(&source, content).unwrap();
            let mut buffer = HexBuffer::new();
            let opened = buffer
                .execute(BufferRequest {
                    file: Some(source.to_str().unwrap().into()),
                    ..request("open")
                })
                .unwrap();
            assert_eq!(opened.size, content.len() as u64, "{extension}");
            assert_eq!(opened.bytes, content, "{extension}");
            buffer
                .execute(BufferRequest {
                    file: Some(output.to_str().unwrap().into()),
                    ..request("save")
                })
                .unwrap();
            assert_eq!(fs::read(&source).unwrap(), content, "{extension}");
            assert_eq!(fs::read(&output).unwrap(), content, "{extension}");
            let compared = buffer
                .execute(BufferRequest {
                    file: Some(output.to_str().unwrap().into()),
                    ..request("compare")
                })
                .unwrap();
            assert_eq!(compared.matches, Some(true), "{extension}");
            assert_eq!(
                compared.other_bytes,
                Some(content.len() as u64),
                "{extension}"
            );
        }
    }

    #[test]
    fn malformed_or_empty_open_preserves_existing_buffer_history_and_source() {
        let (directory, mut buffer, source) = load(&[1, 2, 3]);
        buffer
            .execute(BufferRequest {
                offset: Some(0),
                value: Some(4),
                ..request("edit")
            })
            .unwrap();
        for (name, content) in [
            ("bad.hex", ":03000000010203AA\n"),
            ("bad.srec", "S1060000010203AA\n"),
            ("empty.bin", ""),
            ("overflow.hex", ":02000004FFFFFC\n:01000000AA55\n"),
        ] {
            let malformed = directory.path().join(name);
            fs::write(&malformed, content).unwrap();
            assert!(buffer
                .execute(BufferRequest {
                    file: Some(malformed.to_str().unwrap().into()),
                    ..request("open")
                })
                .is_err());
            assert_eq!(fs::read(&malformed).unwrap(), content.as_bytes());
            assert_eq!(bytes(&mut buffer), [4, 2, 3]);
            assert!(buffer.execute(request("state")).unwrap().can_undo);
        }
        assert_eq!(fs::read(source).unwrap(), [1, 2, 3]);
    }

    #[test]
    fn history_is_limited_and_oldest_entries_are_evicted() {
        let (_directory, mut buffer, _) = load(&[0]);
        for value in 1..=129 {
            buffer
                .execute(BufferRequest {
                    offset: Some(0),
                    value: Some(value),
                    ..request("edit")
                })
                .unwrap();
        }
        assert_eq!(buffer.loaded.as_ref().unwrap().undo.len(), HISTORY_EDITS);
        for _ in 0..HISTORY_EDITS {
            buffer.execute(request("undo")).unwrap();
        }
        assert_eq!(bytes(&mut buffer), [1]);
        assert!(!buffer.execute(request("state")).unwrap().can_undo);
        assert_eq!(buffer.loaded.as_ref().unwrap().redo.len(), HISTORY_EDITS);
    }

    #[test]
    fn partial_replacement_io_failure_restores_bytes_hash_and_history() {
        let data = vec![0x35; CHUNK_BYTES * 2 + 7];
        let (_directory, mut buffer, _) = load(&data);
        let image = buffer.loaded.as_mut().unwrap();
        let before = image.sha256().unwrap();
        let mut truncated = private_file(image.directory.path()).unwrap();
        truncated.write_all(&vec![0xab; CHUNK_BYTES + 1]).unwrap();
        // The first 64 KiB write succeeds before read_exact encounters the
        // truncated second chunk. The rollback must restore that first write.
        assert!(image
            .apply(0..data.len() as u64, Replacement::File(truncated))
            .is_err());
        assert!(image.fault.is_none());
        assert_eq!(
            image.page(0, CHUNK_BYTES as u64).unwrap(),
            data[..CHUNK_BYTES]
        );
        assert_eq!(
            image.page(CHUNK_BYTES as u64, CHUNK_BYTES as u64).unwrap(),
            data[CHUNK_BYTES..CHUNK_BYTES * 2]
        );
        assert_eq!(image.sha256().unwrap(), before);
        assert!(image.undo.is_empty() && image.redo.is_empty());
    }

    #[test]
    fn reply_hash_failure_after_successful_edit_still_reports_dirty() {
        assert!(!HexBuffer::new().is_dirty());
        let (_directory, mut buffer, source) = load(b"abc");
        assert!(!buffer.is_dirty());
        // Inject a read failure in the private image only. Editing offset 0
        // still succeeds, while the ensuing full-image hash reads past EOF.
        buffer
            .loaded
            .as_mut()
            .unwrap()
            .image
            .as_file_mut()
            .set_len(1)
            .unwrap();
        let result = buffer.execute(BufferRequest {
            offset: Some(0),
            value: Some(b'z' as u64),
            count: Some(0),
            ..request("edit")
        });
        assert!(result.is_err());
        assert!(buffer.is_dirty());
        let image = buffer.loaded.as_mut().unwrap();
        assert_eq!(image.undo.len(), 1);
        assert_eq!(image.page(0, 1).unwrap(), b"z");
        assert!(image.hash.is_none());
        assert_eq!(fs::read(source).unwrap(), b"abc");
    }

    #[test]
    fn faulted_buffer_is_dirty_even_with_previously_clean_cached_hash() {
        let (_directory, mut buffer, _) = load(b"abc");
        assert!(!buffer.is_dirty());
        buffer.loaded.as_mut().unwrap().fault = Some("injected rollback failure".into());
        assert!(buffer.is_dirty());
    }

    #[test]
    fn partial_redo_failure_restores_undone_image_and_retains_redo() {
        let data = vec![0x35; CHUNK_BYTES * 2 + 7];
        let (_directory, mut buffer, _) = load(&data);
        let image = buffer.loaded.as_mut().unwrap();
        let mut replacement = private_file(image.directory.path()).unwrap();
        replacement.write_all(&vec![0xab; data.len()]).unwrap();
        image
            .apply(0..data.len() as u64, Replacement::File(replacement))
            .unwrap();
        image.undo().unwrap();
        if let Replacement::File(file) = &mut image.redo.last_mut().unwrap().replacement {
            file.as_file_mut().set_len(CHUNK_BYTES as u64 + 1).unwrap();
        }
        assert!(image.redo().is_err());
        assert!(image.fault.is_none());
        assert_eq!(
            image.page(0, CHUNK_BYTES as u64).unwrap(),
            data[..CHUNK_BYTES]
        );
        assert_eq!(
            image.page(CHUNK_BYTES as u64, CHUNK_BYTES as u64).unwrap(),
            data[CHUNK_BYTES..CHUNK_BYTES * 2]
        );
        assert_eq!(image.redo.len(), 1);
        assert!(image.undo.is_empty());
    }

    #[test]
    fn oversized_sparse_input_is_rejected_before_copy_and_keeps_current_state() {
        let (directory, mut buffer, _) = load(&[7]);
        let oversized = directory.path().join("oversized.bin");
        let file = File::create(&oversized).unwrap();
        file.set_len(MAX_BYTES + 1).unwrap();
        assert!(buffer
            .execute(BufferRequest {
                file: Some(oversized.to_str().unwrap().into()),
                ..request("open")
            })
            .is_err());
        assert_eq!(bytes(&mut buffer), [7]);
    }

    #[test]
    fn serialization_uses_contract_camel_case_and_rejects_bad_fields() {
        let req: BufferRequest = serde_json::from_str(
            r#"{"operation":"open","originChip":"W25Q128","file":"test.bin"}"#,
        )
        .unwrap();
        assert_eq!(req.origin_chip.as_deref(), Some("W25Q128"));
        assert!(
            serde_json::from_str::<BufferRequest>(r#"{"operation":"page","offset":-1}"#).is_err()
        );
        assert!(
            serde_json::from_str::<BufferRequest>(r#"{"operation":"page","command":"rm"}"#)
                .is_err()
        );
        let json = serde_json::to_value(BufferReply::default()).unwrap();
        assert_eq!(json["canUndo"], false);
        assert_eq!(json["canRedo"], false);
        assert!(json.get("foundOffset").is_none());
    }

    #[test]
    #[ignore = "writes and hashes 1.14 GiB and 2 GiB disk images; run explicitly in large-image validation"]
    fn large_fixture_and_exact_two_gib_boundary_have_bounded_pages_and_undo() {
        let directory = tempfile::tempdir().unwrap();
        for size in [1_140_850_688, MAX_BYTES] {
            let source = directory.path().join("large.bin");
            let mut file = File::create(&source).unwrap();
            file.set_len(size).unwrap();
            file.seek(SeekFrom::Start(size - 1)).unwrap();
            file.write_all(&[0xab]).unwrap();
            file.flush().unwrap();
            let mut image = Loaded::open(&source, None).unwrap();
            assert_eq!(image.size, size);
            assert_eq!(image.page(size - 2, 256).unwrap(), [0, 0xab]);
            image
                .apply(size - 1..size, Replacement::Fill(0xcd))
                .unwrap();
            image.undo().unwrap();
            assert_eq!(image.page(size - 1, 1).unwrap(), [0xab]);
            assert!(image.page(0, CHUNK_BYTES as u64 + 1).is_err());
            let mut tail = [0];
            // The original was opened write-only, so verify with a new reader.
            let mut source_reader = File::open(&source).unwrap();
            source_reader.seek(SeekFrom::Start(size - 1)).unwrap();
            source_reader.read_exact(&mut tail).unwrap();
            assert_eq!(tail, [0xab]);
        }
    }
}
