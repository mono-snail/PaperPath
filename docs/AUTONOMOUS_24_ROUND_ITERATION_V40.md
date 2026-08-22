# PaperPath V40: Streamed OOXML Commit

## Product Direction

V40 removes the full-package `Data` assembly step from DOCX, XLSX, and PPTX
production. Validated OOXML entries now stream into a protected temporary file
in the destination directory, followed by the central directory, synchronized
storage, signature and length verification, and an atomic commit.

This is the required foundation for ZIP64 and file-backed package entries.
Increasing archive limits before removing the duplicate in-memory package would
have raised crash risk on large documents.

## Evidence-Based Competitive Baseline

- Adobe exposes Office conversion but does not document local package-level
  memory, file-protection, or atomic-commit evidence:
  <https://helpx.adobe.com/ph_en/acrobat/web/share-review-and-export/export-and-print/export-pdfs.html>
- PDF Expert's iOS feature page does not expose streamed OOXML construction or
  production storage forecasts:
  <https://pdfexpert.com/ios/features>
- UPDF's conversion workflow does not describe protected temporary output,
  crash cleanup, or package byte telemetry:
  <https://updf.com/convert-pdf/batch-pdf-converter/>
- Apple's FileHandle supports incremental file output:
  <https://developer.apple.com/documentation/foundation/filehandle>

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Gain |
|---|---|---|---|
| 1 | OOXMLArchive returned one complete Data value | Audit package ownership | Found peak-memory duplication |
| 2 | Every exporter performed another atomic Data write | Audit DOCX, XLSX, and PPTX call sites | Shared migration boundary |
| 3 | Excel mapped the completed package into memory again | Remove whole-package reopen validation | Lower second peak |
| 4 | ZIP64 on the old path would increase memory risk | Prioritize streaming foundation | Correct dependency order |
| 5 | Stream output needed same-directory atomicity | Create temporary files beside the destination | Rename-safe commit |
| 6 | Temporary files held private document content | Apply complete file protection | Stronger local privacy |
| 7 | Production files must not enter backup | Exclude temporary and final files from backup | Controlled storage |
| 8 | Full local records were assembled in memory | Write each local header and payload immediately | Lower package peak |
| 9 | The central directory was one growing Data value | Write central records one at a time | Bounded metadata writes |
| 10 | Cancellation could leave a partial package | Check cancellation between every entry and central record | Responsive abort |
| 11 | FileHandle failure could strand an empty temp file | Add open-failure cleanup | Stable failure path |
| 12 | DOCX returned package Data to its caller | Write DOCX directly to destination | Removed duplicate package |
| 13 | XLSX returned package Data to its caller | Write XLSX directly to destination | Removed duplicate package |
| 14 | PPTX returned package Data to its caller | Write PPTX directly to destination | Removed duplicate package |
| 15 | Excel reread the complete output | Keep pre-write XML/relationship/content-type validation | No full reopen |
| 16 | Stream output needed deterministic completion proof | Compare actual and forecast archive byte counts | Truncation detection |
| 17 | Length alone could accept the wrong file | Read and verify the four-byte ZIP local-header signature | Format evidence |
| 18 | Buffered writes could remain uncommitted | Synchronize and close before replacement | Durable handoff |
| 19 | Existing destinations needed safe replacement | Use FileManager atomic replacement | Original preservation |
| 20 | Process termination can bypass catch cleanup | Remove OOXML temp files older than six hours on next export | Crash recovery |
| 21 | Storage forecast still assumed two complete output copies | Replace 2x estimate with streamed peak reserve | More accurate capacity |
| 22 | Users needed visible pipeline evidence | Add streamed commit to the compact forecast contract | Explainable behavior |
| 23 | New failure and capacity states needed localization | Add Simplified Chinese strings | Consistent copy |
| 24 | FileHandle, protection, cancellation, three exporters, and UI contract changed together | Build both simulator architectures and extension | Compile integration proof |

## Delivered

- Direct-to-file OOXML archive writing.
- Same-directory temporary output.
- Complete file protection for temporary and final Office files.
- Backup exclusion for production output.
- Incremental local-header and payload writes.
- Incremental central-directory writes.
- Cancellation checks through both archive phases.
- Exact expected-versus-written byte verification.
- ZIP local-header signature verification.
- Synchronized close before atomic commit.
- Existing-destination replacement without exposing partial output.
- Cleanup on creation, writing, verification, and commit failures.
- Six-hour stale OOXML temporary-file recovery.
- DOCX, XLSX, and PPTX migration.
- Removal of Excel whole-package mapped verification.
- Stream-aware storage forecast and high-density capacity contract.

## Competitive Gain

- Versus Acrobat web, PaperPath exposes a local protected and atomic Office
  production path without requiring cloud conversion.
- Versus PDF Expert iOS, PaperPath reports actual streamed package bytes and
  storage reserve before production.
- Versus UPDF iOS, PaperPath preserves the previous destination until the new
  package is synchronized and verified.

## Remaining Shortfalls

- Individual OOXML entry payloads are still represented as `Data`.
- Page image and generated XML entries remain resident until archive writing
  completes.
- Traditional ZIP32 limits still apply to entry size, offsets, and entry count.
- A power loss during filesystem replacement still relies on filesystem atomic
  rename guarantees.

## Next Precise Direction

1. Add file-backed and producer-backed OOXML entry sources.
2. Release large visual entries immediately after they are written.
3. Add ZIP64 local/central extras and ZIP64 end records.
4. Add data-descriptor mode for single-pass checksum and writing.

## Build

`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Result: succeeded for arm64 and x86_64 simulator architectures with the Share
Extension embedded. Unit tests, UI tests, screenshots, and release gates were
intentionally not run.
