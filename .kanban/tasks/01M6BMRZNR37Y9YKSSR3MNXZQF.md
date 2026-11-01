---
comments:
- actor: claude-code
  id: 01m6bywygw322q240s5tgs6rky
  text: |-
    ### implement — changed
    - evidence: swift test exit 0, 1642 + 401 tests pass. New suite LocalModelPathTests (10 tests; red was a compile failure on the missing ModelRef.localDirectory).
    - files: Sources/FoundationModelsExtras/ModelPool/{ModelRef,HubModelLoader,MLXModelLoader,CoreMLModelLoader,CoreMLEmbedding,CoreMLPackage}.swift, Tests/FoundationModelsExtrasTests/ModelPool/LocalModelPathTests.swift, docs/REFERENCE.md
    - design choice: a reference is local when its repo string is the path of an existing directory (as the card says). A Hub name that equals a folder relative to the working directory would load as local. A path with an @ splits as a revision.
    - Core ML compiled cache for a local folder is keyed by path plus manifest mtime.
    - Router tests use Hub names only; no old-behavior expectation found.
    - next: /review
  timestamp: 2026-11-01T16:25:50.876749+00:00
- actor: claude-code
  id: 01m6bz1aebp27sydxy5dnz7a0n
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD, 4 findings (4 confirmed, 0 refuted): CoreMLModelLoader.swift:149, CoreMLPackage.swift:160, CoreMLPackage.swift:162, HubModelLoader.swift:175
    - next: fix the 4 open findings, then run review again
  timestamp: 2026-11-01T16:28:14.155594+00:00
- actor: claude-code
  id: 01m6bz1jt6709p5rd1b0a6xagm
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 8 files
    - test: green — swift test exit 0, 1642 passed
    - commit: 1355ab0
    - review: findings — CoreMLModelLoader.swift:149, CoreMLPackage.swift:160, CoreMLPackage.swift:162, HubModelLoader.swift:175
  timestamp: 2026-11-01T16:28:22.726993+00:00
- actor: claude-code
  id: 01m6bz68fg7gr5g6bchm042zqx
  text: |-
    ### implement — changed
    - evidence: swift test exit 0, 1647 tests pass, no warning from the code. New tests red first (compile failure on the missing API), then green.
    - fix 1: HubSource.modelFolder(of:revision:) is the one local-or-cache lookup. MLXModelLoader.snapshotDirectory, CoreMLModelLoader.footprintBytes and HubModelLoader.format use it. Each loader keeps its own error type.
    - fix 2: CoreMLPackage.localRevision is a SHA-256 digest of the relative path, size and mtime of every regular file in the package. A test changes a weight file in place and checks the revision changes.
    - fix 3: localRevision throws CoreMLModelLoaderError.unreadablePackage(path:). No try? fallback. CoreMLEmbedding.load passes the error on.
    - fix 4: HubModelLoader.format resolves one folder, lists and detects once. A local folder that is empty or unreadable throws the new HubModelLoaderError.unreadableLocalFolder(path:). Before, an empty local folder gave MLX.
    - docs/REFERENCE.md and the CoreMLModelLoader doc comment say the same.
    - files: ModelPool/{HubSource,MLXModelLoader,CoreMLModelLoader,CoreMLPackage,CoreMLEmbedding,HubModelLoader}.swift, Tests/.../LocalModelPathTests.swift, docs/REFERENCE.md
    - next: /review
  timestamp: 2026-11-01T16:30:55.984126+00:00
position_column: doing
position_ordinal: '80'
title: HubModelLoader detects the model format from a local path
---
The agent config must accept a local path as a model reference and find the format by itself: a .mlpackage folder is CoreML, safetensors files are MLX. HubModelFormat.detect works on the files of a Hub repository only. HubModelLoader.format(of:) looks in the Hub cache or asks the Hub. Add a local-path branch: when the reference is an existing directory, list its top-level names and call HubModelFormat.detect. Make MLXModelLoader and CoreMLModelLoader load from that directory with no download. Add tests for a CoreML folder, an MLX folder, and a folder with both. Coordinated with: FoundationModelsRouter ^y18w1dp (ModelRef accepts a local model path), FoundationModelsRouter ^zpcsp86 (LiveModelLoader uses HubModelLoader), FoundationModelsACPAgent ^gsxzx6h (default embedding and config path).

## Review Findings (2026-11-01 10:26)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `docs/REFERENCE.md` — no validator matches this file

- [x] `Sources/FoundationModelsExtras/ModelPool/CoreMLModelLoader.swift:149` `reuse/reuse` — footprintBytes resolves a local folder or a cache snapshot with its own expression. MLXModelLoader already has the same resolution in snapshotDirectory(of:), which checks localDirectory first and then the cache. Two loaders now hold the same rule, so a change to one (for example to the error or the revision handling) will not reach the other. Move the local-or-cache resolution to one shared place, such as a method on HubSource that takes a ModelRef and a revision and returns the folder or nil. Have both MLXModelLoader.snapshotDirectory and CoreMLModelLoader.footprintBytes call it, and keep each loader's own error type at its call site.
- [x] `Sources/FoundationModelsExtras/ModelPool/CoreMLPackage.swift:160` `completeness/invariant-propagation` — The compiled-model key for a local package changes only when Manifest.json changes. The doc comment says a package that changes in place compiles again, but a change to the weight files without a manifest change keeps the old compiled model. The stated guarantee is wider than the code. Either include the modification dates or sizes of the weight files in `localRevision`, or narrow the doc comment and the change description so they say only a manifest change triggers a new compile. Add a test that changes a weight file in place and checks that the revision changes.
- [x] `Sources/FoundationModelsExtras/ModelPool/CoreMLPackage.swift:162` `swift/preconditions` — The manifest date read uses `try?` and falls back to `.distantPast` with no `assertionFailure` and no log. If the manifest cannot be read, every later state of the package gets the same revision string, so a package that changes in place is not compiled again. This is the defect the change exists to prevent, and the failure is silent. When the read fails, call `assertionFailure` and write a log line that names the manifest path, then keep the fallback. Alternatively, make `localRevision` throw a typed error and let `CoreMLModelLoader` report it.
- [x] `Sources/FoundationModelsExtras/ModelPool/HubModelLoader.swift:175` `reuse/reuse` — The new local-folder branch in format(of:) repeats the snapshot branch below it (contentsOfDirectory, then HubModelFormat.detect(paths:)). Two copies of the same folder-to-format step can diverge. The local branch also omits the non-empty check and the try? handling that the snapshot branch uses, so the two paths already differ. Resolve one folder first, then run the listing and detect once. For example: let folder = key.ref.localDirectory ?? hub.snapshotDirectory(of:revision:); if let folder, let names = try? contentsOfDirectory(...), !names.isEmpty { return detect(names) }. Decide in one place whether an empty or unreadable local folder should throw.
