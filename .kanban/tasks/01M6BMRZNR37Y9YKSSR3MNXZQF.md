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
- actor: claude-code
  id: 01m6bza8atyjed3pgsrrebaw73
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD; 2 findings — CoreMLPackage.swift:183, HubModelLoader.swift:181
    - next: the implementer fixes both open items, then the task is reviewed again
  timestamp: 2026-11-01T16:33:06.906280+00:00
- actor: claude-code
  id: 01m6bzagjypb8wy7xmcrpnygc1
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 8 files
    - test: green — swift test, 1647 passed
    - commit: 6b5f6dd
    - review: findings — CoreMLPackage.swift:183, HubModelLoader.swift:181
  timestamp: 2026-11-01T16:33:15.358312+00:00
- actor: claude-code
  id: 01m6bzg2bktgeq8whbq9gqm4eg
  text: |-
    ### implement — changed
    - evidence: swift test exit 0, 1650 + 401 tests pass, no warning from the code. New tests red first (compile failure on the missing revisionLine), then green.
    - fix 1: CoreMLPackage.revisionLine(relative:size:changed:path:) is the one place that builds the digest line of a file. It throws unreadablePackage(path:) when the size or the date is nil. localRevision calls it, so no "?? 0" fallback is left in the file. Tests: missing date throws, missing size throws, only the date of a weight file changes.
    - fix 2: HubModelLoader.format(of:) resolves the folder and the names first. A separate guard throws unreadableLocalFolder for a local reference with no names, before the Hub branch.
    - discovery: a real file system always reports size and date, so the nil path is tested through the revisionLine seam.
    - files: ModelPool/CoreMLPackage.swift, ModelPool/HubModelLoader.swift, Tests/.../LocalModelPathTests.swift
    - both findings flipped to [x]. Not committed.
    - next: /review
  timestamp: 2026-11-01T16:36:17.395091+00:00
- actor: claude-code
  id: 01m6bzgj6k3dxnhs3dysk0ekgv
  text: |-
    ### commit — changed
    - evidence: e2f3007 fix(model-pool): a local revision needs a real size and a real date
    - next: none
  timestamp: 2026-11-01T16:36:33.619117+00:00
- actor: claude-code
  id: 01m6bzk1wn381eztmrxd22a8bh
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD, 1 finding: Tests/FoundationModelsExtrasTests/ModelPool/LocalModelPathTests.swift:168
    - next: remove the copied test body with one shared helper that takes the mutation as a closure, then review again
  timestamp: 2026-11-01T16:37:55.221093+00:00
- actor: claude-code
  id: 01m6bzk8vts8h0mmrv95m8y8j4
  text: |-
    ### finish iteration 3 — findings
    - implement: changed — 3 files
    - test: green — swift test, 1650 passed
    - commit: b09a63a
    - review: findings — LocalModelPathTests.swift:168
  timestamp: 2026-11-01T16:38:02.362581+00:00
- actor: claude-code
  id: 01m6bzn2dgthy1csntv9ak64gj
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsExtrasTests/ModelPool/LocalModelPathTests.swift. The three compiled-place tests now call one private helper, expectRevisionChange, with their own change closure. Two other copied blocks left the file: setDate(of:) and emptyHub(in:). Full swift test: 1650 tests in 162 suites passed.
    - next: review
  timestamp: 2026-11-01T16:39:01.296331+00:00
- actor: claude-code
  id: 01m6bzqg37kz3136xaaxk64z94
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD, 0 findings (0 confirmed, 0 refuted); all prior findings are checked
    - next: none, task moved to done
  timestamp: 2026-11-01T16:40:20.839919+00:00
- actor: claude-code
  id: 01m6bzqnhp1fmpp1pbqhf4kj1e
  text: |-
    ### finish iteration 4 — clean
    - implement: changed — 1 file
    - test: green — swift test, 1650 passed
    - commit: c27475b
    - review: clean — 0 findings
  timestamp: 2026-11-01T16:40:26.422052+00:00
position_column: done
position_ordinal: ffcd80
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

## Review Findings (2026-11-01 10:31)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 3 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `docs/REFERENCE.md` — no validator matches this file

- [x] `Sources/FoundationModelsExtras/ModelPool/CoreMLPackage.swift:183` `completeness/public-output-contract` — The local revision replaces a missing modification date with 0 (`values.contentModificationDate?.timeIntervalSince1970 ?? 0`), and line 185 does the same for a missing file size with `?? 0`. The doc comment on `localRevision` says there is no fallback value, because a fallback keeps an old compiled model. With this fallback, a file whose date the file system does not report adds the same digest entry in every state, so an in-place change to that file would not be seen and the stale compiled model would load. The code silently does what the new `unreadablePackage` throw was meant to prevent. Throw `CoreMLModelLoaderError.unreadablePackage(path: entry.path)` when `contentModificationDate` or `fileSize` is nil, as the code already does for a failed `resourceValues` read. This keeps the no-fallback rule the doc states. Optionally add a test where the weight file keeps its size but gets a new modification date, so the date path is exercised on its own.
- [x] `Sources/FoundationModelsExtras/ModelPool/HubModelLoader.swift:181` `swift/preconditions` — The requirement that a local folder must not be empty or unreadable sits as a nested `if isLocal { throw ... }` inside the `if let folder` branch. The check is hidden inside the branch it protects, so a reader must enter the outer branch to find it. Keep the `if let` at line 178, because a nil folder must fall through to the Hub lookup and a `guard` cannot express that. Move the local-folder requirement to the head of the block as a separate `guard` that runs when `isLocal` is true and the names are empty or unreadable, so the throw is stated before the Hub branch is read.

## Review Findings (2026-11-01 10:36)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsExtrasTests/ModelPool/LocalModelPathTests.swift:168` `reuse/reuse` — The new test compiledPlaceChangesWithTheDateOfAWeightFile copies the body of the existing test compiledPlaceChangesWithAWeightFile. Both write the Core ML folder, locate the package, take `before`, mutate one weight file, and assert the revision changed. Only the mutation line differs. A second copy means the setup can drift between the two tests. Extract a private static helper that takes the mutation as a closure, for example `assertRevisionChanges(after mutate: (URL) throws -> Void)`. Both tests then call the helper with their own mutation. Keep the two mutations as separate, visible arguments at each call site.
