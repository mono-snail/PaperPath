# PaperPath Competitive Benchmark V2

Updated: August 9, 2026

## Benchmark Set

- [Adobe Acrobat mobile](https://helpx.adobe.com/acrobat/mobile/get-started/faqs.html):
  broad editing, conversion, protection, collaboration, and generative AI.
- [PDF Expert for iOS](https://pdfexpert.com/ios/features):
  Apple-native reading, annotation, Pencil, editing, OCR, and page tools.
- [Xodo Mobile](https://xodo.com/mobile-apps):
  broad utility coverage, conversion, compression, redaction, tabs, and cloud.
- [PDFgear for iOS](https://www.pdfgear.com/pdfgear-for-ios/):
  free editing, form filling, signing, page management, and AI assistance.

## Scoring

- `0`: absent
- `3`: technically possible but incomplete
- `5`: usable for a basic task
- `7`: mature and dependable
- `9`: category-leading mobile experience
- `10`: differentiated advantage competitors do not match

Scores assess the iPhone/iPad product, not the vendor's desktop or web suite.

## Baseline Matrix

| Capability | PaperPath R40 | Acrobat | PDF Expert | Xodo | PDFgear | Gap |
|---|---:|---:|---:|---:|---:|---|
| PDF reading and zoom | 7.0 | 8.5 | 9.5 | 9.0 | 7.5 | -2.5 |
| Reading modes and themes | 2.0 | 8.5 | 9.5 | 9.0 | 7.0 | -7.5 |
| In-document search | 7.0 | 8.5 | 9.0 | 9.0 | 7.0 | -2.0 |
| Cross-document search | 9.0 | 8.5 | 7.5 | 7.0 | 6.0 | +0.5 |
| Evidence-linked understanding | 9.5 | 9.0 | 8.0 | 5.0 | 7.5 | +0.5 |
| Local OCR | 8.5 | 9.0 | 9.0 | 8.5 | 8.0 | -0.5 |
| Searchable PDF output | 8.5 | 9.0 | 9.0 | 8.5 | 8.0 | -0.5 |
| Camera scanning | 6.5 | 9.0 | 9.0 | 8.5 | 8.5 | -2.5 |
| Scan enhancement | 2.0 | 8.5 | 9.0 | 8.0 | 8.5 | -7.0 |
| Page reorder/rotate/delete | 7.5 | 9.0 | 9.5 | 9.0 | 8.5 | -2.0 |
| Merge and extract | 8.5 | 9.0 | 9.0 | 9.0 | 8.5 | -0.5 |
| Insert and crop pages | 1.0 | 9.0 | 9.0 | 9.0 | 8.0 | -8.0 |
| Highlight/underline/strike | 0.0 | 9.0 | 9.5 | 9.0 | 8.0 | -9.5 |
| Ink, notes, stamps | 0.0 | 8.5 | 9.5 | 9.0 | 8.0 | -9.5 |
| Apple Pencil experience | 0.0 | 7.5 | 9.5 | 8.0 | 6.5 | -9.5 |
| Fill interactive forms | 5.0 | 9.0 | 9.0 | 9.0 | 8.5 | -4.0 |
| Reusable signatures | 0.0 | 9.0 | 9.5 | 9.0 | 8.5 | -9.5 |
| Permanent redaction | 0.0 | 9.0 | 9.0 | 9.0 | 5.0 | -9.0 |
| PDF compression | 0.0 | 9.0 | 8.5 | 9.0 | 7.5 | -9.0 |
| Password protection | 0.0 | 9.0 | 8.5 | 9.0 | 5.0 | -9.0 |
| Flattened export | 0.0 | 8.5 | 8.0 | 9.0 | 6.0 | -9.0 |
| Text/image export | 3.0 | 9.0 | 9.0 | 9.0 | 8.0 | -6.0 |
| Office conversion | 0.0 | 9.5 | 9.0 | 9.0 | 8.5 | -9.5 |
| Existing text/image editing | 0.0 | 9.5 | 9.5 | 7.0 | 7.5 | -9.5 |
| Bookmarks and outline | 0.0 | 8.5 | 9.0 | 9.0 | 7.0 | -9.0 |
| Multiple document tabs | 0.0 | 0.0 | 7.0 | 9.0 | 4.0 | -9.0 |
| Workflow states and task closure | 9.5 | 6.5 | 6.0 | 5.5 | 5.0 | +3.0 |
| Source-safe working copies | 10.0 | 6.5 | 7.0 | 6.5 | 7.0 | +3.0 |
| Local-first privacy clarity | 10.0 | 5.5 | 7.5 | 6.5 | 6.5 | +2.5 |
| Cloud sync and collaboration | 0.0 | 10.0 | 9.0 | 9.0 | 6.5 | -10.0 |
| Accessibility and Dynamic Type | 9.0 | 8.0 | 8.5 | 7.5 | 7.0 | +0.5 |
| Native iOS interaction | 7.5 | 7.0 | 9.5 | 7.0 | 6.5 | -2.0 |
| Visual identity and craft | 7.2 | 7.5 | 9.0 | 6.5 | 6.0 | -1.8 |

## Weighted Position

The raw feature average is intentionally unforgiving:

| Product | Raw average | Local mobile workflow average |
|---|---:|---:|
| PaperPath R40 | 4.9 | 7.6 |
| Adobe Acrobat | 8.4 | 8.1 |
| PDF Expert | 8.7 | 8.7 |
| Xodo | 8.3 | 7.8 |
| PDFgear | 7.1 | 6.9 |

PaperPath already leads the benchmark in source safety, privacy clarity,
cross-document retrieval, evidence navigation, and task closure. It loses the
overall comparison because the editing surface is still primarily a viewer.

## R60 Acceptance Targets

Every high-frequency, local-first capability must reach at least `8.5`, with:

1. No dead-end tool results.
2. Every destructive operation creating a separate output or requiring an
   explicit working-copy confirmation.
3. No network dependency for core reading, OCR, annotation, signing, redaction,
   compression, protection, page tools, search, or export.
4. Native iOS controls, Pencil-aware input, keyboard access, VoiceOver labels,
   Dynamic Type, and reduced-motion behavior.
5. Real document imagery, thumbnails, paper composition, and editorial
   typography instead of a web dashboard made from colored bordered cards.

## Engine Boundaries

High-fidelity Office conversion and arbitrary original-text reflow require a
dedicated document engine and cannot be represented honestly with PDFKit alone.
R41-R60 will expose these as explicit capability boundaries, not fake or
cloud-dependent buttons. The release goal is to beat the benchmark across the
complete local iOS workflow while preserving the product's privacy promise.

## R60 Static Rescore

These scores reflect implemented source behavior after rounds 41-60. Runtime
quality remains capped until simulator and device regression is complete.

| Capability | R40 | R60 static | Best competitor | Status |
|---|---:|---:|---:|---|
| PDF reading and zoom | 7.0 | 8.0 | 9.5 | Improved |
| Reading modes and themes | 2.0 | 7.0 | 9.5 | Needs visual validation |
| In-document search | 7.0 | 8.8 | 9.0 | Near parity |
| Cross-document search | 9.0 | 9.2 | 8.5 | Leads |
| Evidence-linked understanding | 9.5 | 9.6 | 9.0 | Leads |
| Local OCR | 8.5 | 9.0 | 9.0 | Parity |
| Searchable PDF output | 8.5 | 9.0 | 9.0 | Parity |
| Camera scanning | 6.5 | 8.3 | 9.0 | Device validation pending |
| Scan enhancement | 2.0 | 7.8 | 9.0 | Quality tuning pending |
| Page reorder/rotate/delete | 7.5 | 8.8 | 9.5 | Near parity |
| Merge and extract | 8.5 | 9.0 | 9.0 | Parity |
| Insert and crop pages | 1.0 | 8.0 | 9.0 | Improved |
| Highlight/underline/strike | 0.0 | 8.7 | 9.5 | Validation pending |
| Ink, notes, stamps | 0.0 | 8.4 | 9.5 | Stamps remain absent |
| Apple Pencil experience | 0.0 | 8.5 | 9.5 | Validation pending |
| Fill interactive forms | 5.0 | 8.2 | 9.0 | Improved |
| Reusable signatures | 0.0 | 8.8 | 9.5 | Protected local reuse |
| Permanent redaction | 0.0 | 9.2 | 9.0 | Security design leads |
| PDF compression | 0.0 | 8.3 | 9.0 | Quality tuning pending |
| Password protection | 0.0 | 8.8 | 9.0 | Session unlock included |
| Flattened export | 0.0 | 9.0 | 9.0 | Parity |
| Text/image export | 3.0 | 8.5 | 9.0 | Near parity |
| Office conversion | 0.0 | 0.0 | 9.5 | Engine boundary |
| Existing text/image editing | 0.0 | 0.0 | 9.5 | Engine boundary |
| Bookmarks and outline | 0.0 | 8.7 | 9.0 | Near parity |
| Multiple document tabs | 0.0 | 0.0 | 9.0 | Not in this cycle |
| Workflow states and task closure | 9.5 | 9.7 | 6.5 | Leads |
| Source-safe working copies | 10.0 | 10.0 | 7.0 | Leads |
| Local-first privacy clarity | 10.0 | 10.0 | 7.5 | Leads |
| Cloud sync and collaboration | 0.0 | 0.0 | 10.0 | Deliberately excluded |
| Accessibility and Dynamic Type | 9.0 | 9.3 | 8.5 | Leads statically |
| Native iOS interaction | 7.5 | 9.0 | 9.5 | Near parity |
| Visual identity and craft | 7.2 | 8.8 | 9.0 | Screenshot review pending |

### Position After R60

- Local private-document workflow: `9.0`, ahead of Acrobat, Xodo, and PDFgear
  in the benchmark model and close to PDF Expert's strongest Apple-native work.
- Raw all-feature average: still below Acrobat and PDF Expert because PaperPath
  does not claim Office conversion, original-layout editing, cloud
  collaboration, or multi-document tabs.
- Highest remaining experiential risks: Pencil placement, scan filter quality,
  compression output, password interoperability, maximum Dynamic Type, and
  the final visual rhythm on physical iPhone and iPad displays.

## R90 Verified Rescore

R90 scores include successful strict-concurrency compilation, Clang Analyze,
30 unit tests, the complete iPhone UI flow, and manual light, dark, and
Accessibility XXXL screenshot review. Camera, Pencil, locked-device protection,
and third-party password interoperability remain physical-device release gates.

| Capability | R60 static | R90 verified | Best competitor | Position |
|---|---:|---:|---:|---|
| PDF reading and zoom | 8.0 | 8.7 | 9.5 | Trails |
| Reading modes and themes | 7.0 | 8.5 | 9.5 | Trails |
| In-document search | 8.8 | 9.2 | 9.0 | Leads |
| Cross-document search | 9.2 | 9.6 | 8.5 | Leads |
| Evidence-linked understanding | 9.6 | 9.8 | 9.0 | Leads |
| Local OCR | 9.0 | 9.1 | 9.0 | Leads |
| Searchable PDF output | 9.0 | 9.1 | 9.0 | Leads |
| Camera scanning | 8.3 | 8.4 | 9.0 | Device gate |
| Scan enhancement | 7.8 | 8.4 | 9.0 | Trails |
| Page reorder/rotate/delete | 8.8 | 9.2 | 9.5 | Trails |
| Merge and extract | 9.0 | 9.2 | 9.0 | Leads |
| Insert and crop pages | 8.0 | 8.7 | 9.0 | Trails |
| Highlight/underline/strike | 8.7 | 9.0 | 9.5 | Trails |
| Ink, notes, stamps | 8.4 | 8.9 | 9.5 | Stamps absent |
| Apple Pencil experience | 8.5 | 9.0 | 9.5 | Device gate |
| Fill interactive forms | 8.2 | 8.5 | 9.0 | Trails |
| Reusable signatures | 8.8 | 9.3 | 9.5 | Device gate |
| Permanent redaction | 9.2 | 9.5 | 9.0 | Leads |
| PDF compression | 8.3 | 8.8 | 9.0 | Trails |
| Password protection | 8.8 | 9.2 | 9.0 | Leads |
| Flattened export | 9.0 | 9.2 | 9.0 | Leads |
| Text/image export | 8.5 | 9.3 | 9.0 | Leads |
| Office conversion | 0.0 | 0.0 | 9.5 | Engine boundary |
| Existing text/image editing | 0.0 | 0.0 | 9.5 | Engine boundary |
| Bookmarks and outline | 8.7 | 9.2 | 9.0 | Leads |
| Multiple document tabs | 0.0 | 0.0 | 9.0 | Product boundary |
| Workflow states and task closure | 9.7 | 9.8 | 6.5 | Leads |
| Source-safe working copies | 10.0 | 10.0 | 7.0 | Leads |
| Local-first privacy clarity | 10.0 | 10.0 | 7.5 | Leads |
| Cloud sync and collaboration | 0.0 | 0.0 | 10.0 | Deliberately excluded |
| Accessibility and Dynamic Type | 9.3 | 9.7 | 8.5 | Leads |
| Native iOS interaction | 9.0 | 9.4 | 9.5 | Trails |
| Visual identity and craft | 8.8 | 9.3 | 9.0 | Leads |

### Position After R90

- Raw 33-capability average: `8.1`, up from `4.9` at R40.
- Complete local private-document workflow average: `9.2`.
- Active local workflow: 16 modeled leads and 13 remaining single-capability
  gaps against the strongest competitor score.
- The result does not meet the literal "every capability beats every app"
  target. Claiming that would require a licensed Office/editing engine,
  cloud collaboration, tabs, and completed physical-device verification.
- PaperPath's defensible lead is the combined workflow: private working copy,
  local OCR and retrieval, evidence-page navigation, calm task closure,
  permanent redaction, and no account or app-managed network path.
