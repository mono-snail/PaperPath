# PaperPath V21: Office Preflight Clarity Loop

## Product Direction

V21 turns Office export recommendation into preflight evidence. V20 made the
Office route actionable; V21 explains why that route is safe, needs review, or
is limited. The export sheet now exposes compact signals for rights, structure,
visual budget, and package scale before the user starts conversion.

## Competitive Baseline

- PDF Expert lists export formats clearly, but the user still has to infer why
  conversion quality may vary.
- Adobe Acrobat has extensive conversion capability, but normal users often see
  opaque conversion results rather than a compact pre-export explanation.
- PDFgear offers broad export routes, but route risks are not presented as a
  dense, local evidence strip.
- PaperPath's advantage is evidence-led Office export: recommendation, preflight,
  route score, budget, fallback, and receipt all remain visible in one compact
  workflow.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | Recommendation lacked explicit cause | Add structured preflight signals | Clearer route trust |
| 2 | Rights risk was buried in text | Add Rights signal | Permission limits visible |
| 3 | Text coverage needed first-class evidence | Add Structure signal | Faster editable-route judgment |
| 4 | Visual budget pressure was disconnected from recommendation | Add Visual signal | Better layout-risk reading |
| 5 | Large package risk needed compact display | Add Package signal | Better large-doc expectation |
| 6 | UI risk copy was free-form | Create `PDFOfficePreflightSignal` | Reusable evidence model |
| 7 | Lead warning should be deterministic | Add lead signal selection | Stronger caution line |
| 8 | Summary should be glanceable | Add preflight summary counts | Faster triage |
| 9 | Protected PDFs need explicit limited state | Rights uses limited readiness | Honest route state |
| 10 | Low text PDFs need safer routing | Structure uses limited readiness under low coverage | Prevent bad expectations |
| 11 | Mixed text PDFs need review state | Structure review threshold | Better intermediate handling |
| 12 | Tight visual budget should not block export | Visual uses review state | Useful warning without false block |
| 13 | Single package should read as safe | Package strong state | Less unnecessary anxiety |
| 14 | Multi-package should be visible | Package review/limited state | Large workflow clarity |
| 15 | UI must remain dense | Add token strip, no new page | Higher information density |
| 16 | Narrow screens need safe layout | Use `ViewThatFits` two-row fallback | Better device fit |
| 17 | Icons should encode source of risk | Use SF Symbols per signal | Faster scanning |
| 18 | Values should not shift layout | Use monospaced digits | Stable metrics |
| 19 | Details should exist without clutter | Attach signal help text | Optional explanation |
| 20 | Recommendation should use preflight | Caution line uses lead signal | Better route narrative |
| 21 | Model/View separation needed | Derive signals in portfolio model | Cleaner UI code |
| 22 | Privacy must remain local | Use only local document profile | No cloud dependency |
| 23 | Scope should stay narrow | Touch model, export sheet, docs only | Lower regression risk |
| 24 | Iteration needs closure | Document V21 and compile Debug | Auditable handoff |

## Delivered

- Added `PDFOfficePreflightSignal`.
- Added structured Rights, Structure, Visual, and Package signals.
- Added preflight lead signal, limited/review counts, and summary copy.
- Updated the Office caution line to use the strongest preflight issue.
- Added a compact Office preflight strip below the recommended route.
- Added two-row fallback layout for narrow widths.
- Added per-signal symbols, readiness colors, monospaced values, and help text.

## Competitive Gain

- Compared with PDF Expert, PaperPath now explains why the recommended Office
  target is appropriate before export.
- Compared with Acrobat, PaperPath keeps preflight understandable in the normal
  workflow rather than hiding it behind advanced conversion internals.
- Compared with PDFgear, PaperPath makes route risk visible as structured local
  evidence instead of only listing target formats.

## Remaining Shortfalls

- Preflight still uses document profile signals, not a full page-level Office
  analysis pass.
- Table detection is still inferred indirectly for route planning.
- Signal help text is attached to controls but not yet persisted into receipts.
- Format-specific post-export receipts still need deeper diagnostics.

## Next Precise Direction

1. Add page-level Office analysis cache for real table, image, and fallback
   counts.
2. Persist preflight signals into Office export receipts.
3. Add compact fallback tradeoff preview before immediate alternate export.
4. Extend the same preflight signal vocabulary to PPTX and XLSX receipts.

## Build

`xcodebuild -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build`

Result: succeeded.
