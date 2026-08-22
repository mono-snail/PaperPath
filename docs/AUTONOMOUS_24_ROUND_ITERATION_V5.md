# PaperPath V5: 24-Round Workbench Iteration

## Product Direction

PaperPath is a private PDF workbench, not a wall of tools. The V5 home screen
must answer three questions in one viewport:

1. What needs attention?
2. What can I do now?
3. Where are my working copies?

The interface should feel like a professional document application: compact,
quiet, information-rich, and native. It must not resemble a marketing page or
a collection of unrelated rounded cards.

## Competitive Baseline

- PDF Expert is strongest at direct manipulation and Apple-platform fluency,
  but original preservation and delivery proof remain implicit.
- Acrobat is strongest at breadth and enterprise workflows, but account, cloud,
  AI, subscription, and layered navigation make the common path heavy.
- PDFgear exposes many tools at low cost, but the product reads as a utility
  catalog rather than an explainable document workflow.
- PaperPath should combine direct manipulation with an explicit private-copy
  model, outcome-led task planning, and verified delivery.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | The product can still read as a PDF utility catalog | Reframe the primary surface as a private document workbench | Stronger product identity |
| 2 | iPad wastes the detail column before a document is selected | Use a full-width navigation workspace on every device | No empty first-screen canvas |
| 3 | The home hero consumes space without helping decisions | Replace it with a compact workbench header | More useful content above the fold |
| 4 | Library health is hidden in prose | Add parallel document, searchable, attention, and verified metrics | Faster scanning |
| 5 | Import, scan, photos, and paper creation are scattered | Consolidate them into one intake command deck | One predictable creation path |
| 6 | Outcome cards repeat borders and descriptions | Convert outcomes into a compact adaptive matrix with custom task artwork | Higher density without losing visual identity |
| 7 | Active work and due work are separate mental models | Rank them in one explainable Next Up queue | Less navigation and duplication |
| 8 | Verified outputs are buried as another section | Present them as a compact delivery ledger | Trust becomes operational, not decorative |
| 9 | Smart views appear after low-value content | Move document-state filters beside the workbench controls | Faster triage |
| 10 | Tool discovery is either too shallow or too long | Use an adaptive quick-tool matrix with explicit expansion | More capability per viewport |
| 11 | Tool cards spend space on repeated borders | Use icon plates, type hierarchy, and separators instead of boxes | Less assembled-card appearance |
| 12 | Library controls occupy too many independent affordances | Consolidate count, selection, sort, density, and view into one header | Lower chrome cost |
| 13 | Default document rows are too tall | Make compact rows the default while preserving Dynamic Type | Higher useful density |
| 14 | Each document row nests another recommendation card | Flatten the next action into the row surface | One object, one interaction boundary |
| 15 | Empty states duplicate onboarding | Use a compact illustrated intake row | Less dead space |
| 16 | The document workspace stacks several status strips | Merge context, progress, receipt, and next action into a compact command strip | More room for the PDF |
| 17 | Page navigation and actions consume two full bars | Rebalance controls into one denser bottom workspace | More visible page area |
| 18 | The tool palette starts with another large hero | Replace it with a compact document context header | Faster access to tools |
| 19 | Tool groups are long single-column lists | Use adaptive two-column groups on wide layouts | Better iPad use |
| 20 | Unavailable tools interrupt normal scanning | Separate availability reason from primary enabled actions | Clearer capability model |
| 21 | Motion reveals every home section independently | Remove decorative staged reveals from recurring work surfaces | Faster, calmer rendering |
| 22 | The cream-heavy palette makes every surface visually similar | Move to cool paper neutrals with semantic cyan, mint, amber, and blue | Better hierarchy and less theme monotony |
| 23 | Large radii and shadows amplify the card collage effect | Tighten radii, shadows, and separators globally | More professional document-tool character |
| 24 | Repeated state publication and eager visual work add noise | Keep state changes value-driven and cap visual work by context | Better startup and scrolling stability |

## Deliberate Non-Goals

- No account, online AI, upload pipeline, advertising SDK, streak, points, or
  engagement notification system.
- No new generic PDF feature whose only purpose is matching a competitor list.
- No automated tests, UI tests, screenshot gate, StoreKit gate, or physical
  device pass in this product iteration.
- Existing PDF structure-preservation and output-audit constraints remain
  unchanged.

## Completion Contract

- Implement all 24 rounds as one coherent product system.
- Preserve all existing working-tree changes.
- Keep English and Simplified Chinese UI coherent.
- Finish with a signed Debug simulator build only.

## Cycle Closure

### Delivered

- Replaced the empty iPad split-detail launch with one full-width workbench and
  a predictable push-navigation document flow.
- Replaced the large home hero with a compact title, custom document artwork,
  and parallel PDF, searchable, attention, and verified metrics.
- Consolidated import, scan, photos, paper creation, and the primary verified
  delivery path into one command deck.
- Rebuilt suggested outcomes and PDF tools as adaptive matrices: two columns on
  compact widths and four on regular widths.
- Moved Smart Views beside the workbench controls, before task and tool
  inventories.
- Kept Next Up and the delivery ledger as dense, explainable rows with direct
  continuation and sharing actions.
- Consolidated library selection, sort, density, and view controls; compact
  rows are now the default.
- Flattened document rows and next actions into one surface with separators,
  instead of a card containing another action card.
- Reduced search, empty-library, loading, and onboarding visual height while
  preserving custom document illustrations.
- Merged document category, summary, page position, verification state, and
  contextual next action into one workspace command strip.
- Stabilized the bottom document bar as Find, Markup, Pages, Verify/Share, and
  Recent Tool. Contextual recommendations no longer reorder the bar.
- Rebuilt Document Tools for a compact header, two-column wide layout,
  favorites/recent commands, and a separately disclosed unavailable section.
- Replaced the cream-heavy palette with cool paper neutrals and tightened
  global radii, shadows, icon plates, controls, and empty states.
- Removed staged reveal animations from the recurring home work surface,
  reduced decorative canvas work, prevented stale thumbnails during revision
  changes, removed duplicate external-inbox startup work, deduplicated external
  routes, and made notice dismissal cancellation-safe.

### Competitive Gain

- Compared with PDF Expert, PaperPath now offers similarly direct document
  navigation while making original preservation, next action, and delivery
  status explicit.
- Compared with Acrobat, the common path presents document state and commands
  without an account, cloud home, AI surface, or nested product navigation.
- Compared with PDFgear, capability remains broad but tools are organized by
  outcome and document compatibility instead of appearing as a flat catalog.
- The distinct product moat remains private working copies plus structurally
  audited, receipt-backed output; V5 makes that moat visible in the daily
  workflow instead of explaining it in large promotional surfaces.

### Remaining Shortfalls

- Advanced editors, page organization, batch output, and Office export still
  have independent visual histories and should be normalized to the V5 compact
  command-strip language in the next cycle.
- Very large libraries will eventually need explicit pagination or incremental
  section snapshots rather than deriving every smart-view count from the whole
  in-memory collection.
- iPad could later add an optional inspector panel after a document is open,
  but it should never return to an empty mandatory detail column.
- Physical camera, Pencil, locked-device, and very-large-PDF behavior remain
  outside this compile-only experience cycle.

### Next Precise Direction

1. Apply the compact command-strip system to page organization, form review,
   redaction, compression, and Office export.
2. Introduce incremental library summaries for thousands of working copies.
3. Add an optional iPad inspector for outline, page, receipt, and version
   context without shrinking the initial workbench.
4. Continue removing duplicated explanation wherever a visible state or direct
   action can communicate the same information.
