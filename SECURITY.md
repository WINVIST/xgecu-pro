# Security policy

This policy applies to the [WINVIST/xgecu-pro](https://github.com/WINVIST/xgecu-pro)
fork, including its Rust command-line tools, native macOS app, build scripts,
and release packaging.

## Report a vulnerability privately

Use [GitHub private vulnerability reporting](https://github.com/WINVIST/xgecu-pro/security/advisories/new)
through **Security → Advisories → Report a vulnerability**.
Do not post exploit details, sensitive logs, firmware images, or chip dumps in
a public issue. If the private form is unavailable, open an issue asking for
a private contact method without disclosing the vulnerability.

Please include, where available:

- Release version or commit, operating system, and whether the CLI or GUI is affected.
- Affected command or workflow, expected behavior, and actual behavior.
- Required attacker access and input source: image, database, archive, USB response,
  environment variable, or another source.
- A minimal reproducer or small test fixture, sanitized logs, and the impact you observed.
- For hardware problems: programmer model, firmware version, USB speed, chip model,
  adapter, and database source/version.

Remove credentials, personal paths, serial numbers, and proprietary data from
attachments. A report does not need to damage hardware or contain a full chip
dump to be useful. Use disposable test inputs and hardware you control.

Reports are reviewed as maintainer availability permits; there is no guaranteed
response deadline or bug bounty. Disclosure timing and any upstream coordination
should be agreed through the private report before publishing technical details.
Issues originating in upstream code can still be reported here.

## Supported versions

| Version | Security maintenance |
| --- | --- |
| Latest stable release, currently 1.0.0 | Supported; fixes are delivered in a newer release |
| Older releases and superseded prereleases | No separate security backports; update to the latest stable release |
| Unreleased `main` | Reports welcome; development code is not a supported release |

See [Releases](https://github.com/WINVIST/xgecu-pro/releases) for available updates.

## System scope and trust boundaries

The app and CLI run locally with the invoking user's permissions. They are not
a network service or a multi-user isolation boundary. The operator controls
the chosen programmer, chip, adapter, files, and explicitly selected local database.

Image files, database records, programming algorithms, downloaded archives,
extractor output, and USB responses must nevertheless be treated as untrusted
inputs. Selecting a local database authorizes its use; it does not prove that
its metadata or algorithms are safe. A device identification response is not
cryptographic authentication of the hardware.

Assets include host files and availability, chip contents, programmer firmware,
and the confidentiality of dumps and other user data. Review all reachable
drivers and workflows, including experimental ones; lack of hardware testing
does not exclude a software vulnerability from scope.

## Security invariants

These are requirements for review and future changes, not a claim that every
path has been exhaustively verified:

- Parse malformed images, databases, archives, firmware, and USB responses with
  checked bounds and recoverable errors. Apply resource limits before excessive
  allocation, decompression, or device transfer.
- Bind cached downloads to their source and retain required integrity checks
  on cache reuse. The default vendor archive must match its pinned digest.
  An explicitly selected custom source has different trust and must not silently
  replace the default source's cache.
- Keep extracted files within the intended destination and supervise extractor
  resource use. Do not treat archive filenames or helper output as executable instructions.
- Invoke the bundled GUI helper directly with structured arguments, without a
  shell. Preserve the GUI's programmer-model, chip-ID, and pinned-database gates;
  inherited configuration must not silently override them.
- Validate operation setup and applicable chip-ID checks before destructive
  operations. The GUI must require confirmation for programming and erasing,
  and programming must use a stable snapshot of the confirmed input.
- Honor operation restrictions such as a database entry that is not erasable.
  An explicit CLI override is operator authority, not permission for the GUI to
  bypass its checks automatically.
- End device transactions and remove programming power on success and error
  paths where the transport permits it. A disconnected or faulty device can
  prevent cleanup; software must not claim cleanup or verification succeeded
  when it did not.
- Report failures and verification results accurately. Do not log or publish
  credentials or full user dumps by default, or include private data in release artifacts.

## What is reportable

Report a reachable defect that compromises one of these properties, including
malformed-input crashes or uncontrolled resource consumption, unintended host
file access or overwrite, command execution, cache-integrity failures, exposure
of private data, bypassed destructive-operation checks, or incorrect transfers
that can corrupt chip contents or programmer firmware.

Explain the attack prerequisites, affected versions and workflows, and observed
impact. Severity depends on reachability, required access, and consequences;
neither a parser error nor a hardware warning alone establishes exploitability.

Routine compatibility problems and incorrect operator setup generally belong
in normal issues. A software defect behind those symptoms remains in security
scope. Third-party vendor code, hardware, and archive utilities are maintained
by their respective owners, but unsafe integration or missing controls in this
fork are in scope. No known issue is exempted merely because it has been documented.

## Known limitations and validation coverage

- Public macOS builds are ad hoc signed, not Developer ID signed or Apple notarized.
- Hardware coverage is limited. See the [hardware validation record](mac-app/HARDWARE-VALIDATION.md)
  for the operations actually checked on the target Mac and T76. Catalog selection
  and passing software tests do not establish hardware compatibility.
- The GUI image buffer is limited to 256 MiB; supported raw read workflows can
  stream up to 2 GiB. These are resource bounds, not a promise that every chip
  within them is supported or validated.
- External archive extraction has best-effort runtime and output-tree limits.
  It is not an operating-system sandbox or a strict disk quota; transient output
  can exceed a monitored threshold before the process is stopped.
- Existing audits and tests cover specific versions and paths. They do not
  establish that the entire project is free of vulnerabilities.

Installation details are in the [macOS guide](mac-app/README.md), and remaining
engineering work is tracked in the [roadmap](mac-app/ROADMAP.md).
