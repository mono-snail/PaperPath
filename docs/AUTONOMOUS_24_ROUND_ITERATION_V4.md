# PaperPath Autonomous 24-Round Iteration V4

Updated: August 17, 2026

## Product Decision

PaperPath is not another all-in-one PDF app. Its defendable position is:

> Finish important PDFs privately, preserve the original, and verify the final
> copy before sharing.

The current product already has professional PDF depth. This cycle turns that
depth into a release-ready product system: immediate first-use understanding,
shorter recurring paths, explicit local-first controls, bounded performance,
honest monetization, and a private feedback loop.

## Competitive Baseline

- PDF Expert wins through Apple-platform fluency, reading quality, mature
  editing, and long-term trust.
- Adobe Acrobat wins through enterprise breadth, cloud review, AI, and brand
  confidence, but its mobile proposition is tied to accounts and subscriptions.
- PDFgear resets the price of generic PDF tools by offering broad editing,
  forms, page management, and no ads for free.

PaperPath will not copy cloud collaboration, online AI, engagement tricks, or
feature-count marketing. It must win when a PDF is private, important, and
cannot be sent incorrectly.

## Twenty-Four Product Rounds

Builds, documentation, screenshots, and verification do not count as rounds.

| Round | Diagnosis | Product delivery | Competitive effect |
|---|---|---|---|
| 1 | New users see tools before understanding the promise | Three-step first-run experience: private work, original preservation, verified output | Explains the unique reason before competing on tool count |
| 2 | Onboarding claims can feel abstract | Add an inspectable local sample route that demonstrates a real PDF workflow | Makes value provable without requesting personal files |
| 3 | Returning users need speed, not repeated education | Persist completion and never force onboarding again; keep replay in Settings | Matches mature utility behavior without marketing interruption |
| 4 | Positioning is split across several phrases | Standardize the first-layer promise to “Finish privately. Verify before sharing.” | Sharper memory than generic “PDF tools” claims |
| 5 | Home still starts with a large tool surface | Introduce one dominant Start action with Import, Scan, and Share Extension intake | Shorter first action than feature-grid competitors |
| 6 | Active work is mixed with passive library content | Add a bounded “Next up” queue for checkpoints, due documents, and changed receipts | Turns local metadata into actionable task continuity |
| 7 | Search, filters, tools, and library controls compete visually | Move low-frequency workspace controls behind a compact View menu | Improves scanability without deleting power |
| 8 | Users can resume a file but not understand why it is next | Show a reason, exact page, and action on every resume row | More explainable than a generic recent-files list |
| 9 | External intake can end in an ambiguous library state | Finish Share Extension/Open In handoff and open the imported private copy directly | Removes Files-to-app friction while preserving source safety |
| 10 | Metadata sync currently lacks a user-facing master decision | Make iCloud metadata sync explicit, optional, and off by default | Stronger local-first credibility than account-led competitors |
| 11 | Privacy controls are scattered | Create one Settings center for privacy, appearance, language, storage, and support | Gives users a stable ownership surface |
| 12 | “Local” does not explain temporary exports | Show export lifetime and cleanup behavior in Settings and Privacy Center | Converts hidden implementation into inspectable trust |
| 13 | Users cannot quickly remove all local traces | Add a guarded local-data reset route that preserves no silent leftovers | Provides clear exit ownership without dark patterns |
| 14 | Startup waits for maintenance and analysis work | Split bootstrap into immediate library restore and deferred maintenance | Improves perceived launch without weakening document checks |
| 15 | First-page thumbnails can be repeatedly rendered | Add revision-aware bounded thumbnail memory caching | Reduces scrolling cost and PDFKit churn |
| 16 | Heavy local operations look similar to a frozen screen | Standardize phase, progress, cancellation, and “kept on device” feedback | Makes slower private processing understandable |
| 17 | Large libraries can overwork preview generation | Add user-controlled preview quality with an automatic low-memory mode | Gives predictable performance on older devices |
| 18 | Retention should not rely on spam notifications | Add opt-in due-date reminders only, scheduled locally per document | Useful recall with no promotional push channel |
| 19 | Feedback currently requires exposing a document or writing from scratch | Add a private diagnostics package with no PDF names, bytes, or extracted text | Faster issue reports without analytics SDKs |
| 20 | Release changes are invisible to returning users | Add a concise, replayable What’s New sheet for meaningful workflows only | Communicates compounding value without modal spam |
| 21 | Rating prompts can interrupt failure recovery | Request a rating only after the second successful verified output, never after failure | Ethical review timing instead of coercion |
| 22 | Subscription pricing conflicts with a local utility | Add one-time Verified Output lifetime access after one free real delivery; reading, import, editing, and file recovery remain free | Competes on trust and ownership without overstating what is gated |
| 23 | Purchase failure and offline states can strand the user | Add restore, pending, cancelled, unavailable, cached startup state, and StoreKit-authoritative revocation handling | Commercial path remains recoverable and refunds cannot leave a stale unlock |
| 24 | New surfaces can regress Chinese, Dynamic Type, VoiceOver, or Reduce Motion | Complete bilingual, accessibility, compact iPhone, and iPad adaptation | Keeps native quality at the same level as functional depth |

## Explicit Non-Goals

- No points, streaks, daily check-ins, or artificial task systems.
- No promotional notifications.
- No advertising SDK or document-content analytics.
- No forced account.
- No PDF upload, online AI, or app-managed cloud storage.
- No weekly subscription or fake countdown pricing.
- No physical-device claims in this cycle.

## Acceptance Gates

1. Every new promise is backed by an inspectable setting or working route.
2. Existing source files remain untouched unless replacement is explicitly
   chosen.
3. iCloud metadata is opt-in and never includes PDF bytes, names, OCR text,
   extracted content, passwords, or signatures.
4. Monetization never blocks reading, import, export compatibility checks, or
   recovery of user-created files.
5. All new UI supports English, Simplified Chinese, Dynamic Type, VoiceOver,
   dark appearance, and Reduce Motion.
6. No XCTest is run in this product cycle. The final gate is a complete Debug
   simulator build plus simulator screenshot review.

## Next Cycle

After this cycle, the next work must be driven by physical-device evidence and
real App Store behavior: camera and Pencil feel, locked-device protection,
large-document energy, purchase sandbox behavior, activation, second verified
output rate, and support-bundle issue categories.

## Cycle Closure

All 24 product rounds are implemented in the V4 working tree. The cycle moved
PaperPath from a feature-led PDF library to an outcome-led, local-first delivery
system.

### Delivered System

- Rounds 1-4: three-step first run, inspectable local sample, replayable
  onboarding, and one consistent promise.
- Rounds 5-9: a single home start path, explainable Next Up queue, quieter
  controls, and direct Share Extension intake.
- Rounds 10-13: opt-in iCloud metadata, unified Settings, explicit temporary
  export lifecycle, a separately confirmed remote-metadata delete, and a guarded
  local-only wipe of the app data root, content-derived search history, extension
  inbox, reminders, signatures, and temporary files.
- Rounds 14-17: deferred analysis after library restore, revision-aware bounded
  thumbnail caching, on-device operation feedback, and adaptive preview quality.
- Rounds 18-21: local due reminders only, privacy-preserving diagnostics,
  replayable release notes, and rating requests only after repeated successful
  verified delivery.
- Rounds 22-24: one free real Verified Output, one-time lifetime access for
  unlimited single and batch Verified Output, recoverable StoreKit states,
  StoreKit-authoritative revocation handling, bilingual copy, dark appearance,
  Dynamic Type, Reduce Motion, compact iPhone, and iPad layouts.

### Competitive Gain

- Against PDF Expert, PaperPath now makes original preservation and final-copy
  verification explicit instead of leaving trust as an implementation detail.
- Against Acrobat, the core path needs no account, upload, recurring plan, or
  document-content analytics.
- Against PDFgear, the first screen prioritizes the next outcome rather than a
  dense inventory of generic tools.
- PaperPath's distinct moat is the combination of private working copies,
  structural output audit, persistent receipts, and explainable task recovery.

### Acceptance Evidence

- Complete signed Debug simulator build succeeds with the Share Extension
  embedded.
- English and Simplified Chinese resources pass plist parsing and duplicate-key
  checks; the StoreKit JSON and shared scheme XML parse successfully.
- Clean isolated iPhone and iPad simulators were used to review onboarding,
  home, Settings, What’s New, lifetime access, light appearance, dark appearance,
  and Accessibility XXXL.
- No XCTest was run, as required for this product-experience cycle.

### Remaining Release Gates

- A direct `simctl` launch does not apply the scheme's local StoreKit
  configuration. Product loading, purchase, cancellation, Ask to Buy, restore,
  and refund must still be exercised from an Xcode-launched StoreKit session or
  App Store sandbox before release.
- Opt-in iCloud metadata still needs a signed-in, two-device conflict and delete
  pass.
- Camera, Pencil, locked-device file protection, and sustained large-document
  energy behavior require physical-device evidence.
- Real activation, second Verified Output conversion, and support categories
  must come from voluntary user feedback rather than a document analytics SDK.

### Precise Next Direction

1. Run the complete StoreKit transaction and revocation matrix.
2. Validate opt-in metadata sync, conflict merge, and remote deletion on two
   signed-in devices.
3. Measure cold launch, 300-page navigation, OCR, and batch delivery energy on
   current and older hardware.
4. Audit camera capture, Pencil latency, VoiceOver order, and locked-device
   behavior on physical devices.
5. Use private diagnostics and voluntary feedback to rank the next workflow,
   instead of adding another generic PDF tool by default.
