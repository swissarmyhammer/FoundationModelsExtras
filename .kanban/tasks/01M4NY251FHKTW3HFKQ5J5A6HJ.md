---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4rb7jksf6d9q6fnhg83vw40
  text: |-
    Research done.
    - `TracedCall` and `SpanIdentity` are public in the core target, thus the Marketplace target can use `TracedCall` directly. No copy of it is necessary.
    - `ExtrasTelemetry` (and `ExtrasTelemetry.errorType(of:)`) is internal to the core. The Marketplace target cannot call it. Thus each Marketplace span that must carry `error.type` runs its throwing part through `TracedCall`, which writes `error.type` itself. The pass span is a plain `withSpan` with a body that does not throw: it gets `pass.outcome` and the error status; the child span that threw carries `error.type`. No new shared helper is necessary.
    - The core uses `TracedCall` for each of its spans (also for short steps such as the embed tokenize step), thus the Marketplace spans follow that pattern.
    - `MarketplaceEvent.updateAvailable` (a check, a dry run, or a `nextLaunch` stage) is not `up_to_date`, `updated` or `failed`. The user said to make a correct decision. Decision: the pass outcome has a fourth bounded value `update_available`, because the store did not install that commit, and `up_to_date` would be false.
    - The error descriptions of the transport can hold the URL and the ref. The telemetry records only `error.type` (through `TracedCall`), never `MarketplaceStore.text(of:)`.
  timestamp: 2026-10-12T15:20:51.577988+00:00
- actor: claude-code
  id: 01m4rby307reea0k9zq40tmr2z
  text: |-
    Implementation landed.
    - Spans: `Marketplace.pass` (plain `withSpan`, body does not throw; it gets `marketplace.id`, `pass.kind`, `pass.outcome`, and the error status when it failed). Children through `TracedCall` (each writes one "enter" record): `Marketplace.check_head`, `Marketplace.sync`, `Marketplace.remote_head`, `Marketplace.fetch`, `Marketplace.materialize`. The throwing part of check_head and sync runs inside the span, thus a failure gives that span and the git span the error status and `error.type`.
    - Metrics, made at call time: `Marketplace.passes` (marketplace.id, pass.kind, pass.outcome), `Marketplace.fetch.duration` and `Marketplace.remote_head.duration` (marketplace.id, git.outcome = succeeded|failed). The head-check timer times each read of the remote head, in a check pass and in an update pass.
    - Decision (user said "make a correct decision"): the pass outcome has a fourth value `update_available` for `MarketplaceEvent.updateAvailable`. A local pass and a refused seed update give `up_to_date` (no event).
    - The private helpers changed signature: `fetch(remote:revision:marketplaceID:)`, `remoteHead(of:marketplaceID:)`, `target(ofRemote:pin:marketplaceID:)`. The old fetch body is now `fetchWithTimeout(remote:revision:)`. New helpers: `work(of:atIndex:)`, `reportHead(of:current:atIndex:)`, `installHeadUnderWriterLock(remote:ofIndex:force:)`. All callers are in the same file.
    - Discovery: the closure that an actor method gives to a `nonisolated(nonsending)` parameter is isolated to the actor. `await` on a synchronous actor method there gives the warning "no 'async' operations occur within 'await' expression", thus `materialize` is called with `try` only.
    - An existing guard `PackageLayoutTests.noOtherLibraryTargetDependsOnTracing` said only the core target may link Tracing. The card orders Tracing on the Marketplace target, thus the guard now names the core target and the Marketplace target; `TelemetryDependencyTests` guards that Marketplace links the API product only.
    - `MarketplaceTests` also links `InMemoryTracing`, because the shared test helpers name `FinishedInMemorySpan`.
    - The error text of a failed pass is known only after the pass, thus the content-safety test forbids the URLs, the repository paths, the cache path, the credential and the typed ref through `TelemetryCapture.run(forbidding:)`, then checks the error text with `context.leaks(forbidding:)` of the same capture.
    - RED: the new tests did not compile before `MarketplaceTelemetry` existed (missing symbols). The manifest test could not run alone before the change, because the test bundle needs every test target to build.
  timestamp: 2026-10-12T15:33:09.255999+00:00
- actor: claude-code
  id: 01m4rby8rakxqzp5bjd1252rj2
  text: |-
    ### implement — changed
    - evidence: `swift test` 1033 Swift Testing tests in 91 suites passed (11 known issues that were there before), plus 393 tests in 29 suites (MarketplaceTests) passed; no warning except the mlx-swift "missing creator for mutated node" line of the dependency build. 9 files: Package.swift, Sources/Marketplace/MarketplaceTelemetry.swift (new), Sources/Marketplace/MarketplaceStore.swift, Tests/FoundationModelsExtrasTests/Telemetry/TelemetryDependencyTests.swift, Tests/MarketplaceTests/MarketplaceStoreTests.swift, Tests/MarketplaceTests/MarketplaceTelemetryExpectations.swift (new), Tests/MarketplaceTests/MarketplaceTelemetryTests.swift (new), Tests/MarketplaceTests/PackageLayoutTests.swift. No shared helper in the core was necessary: `TracedCall` is public.
    - next: /review
  timestamp: 2026-10-12T15:33:15.146359+00:00
- actor: claude-code
  id: 01m4rbydrb2rxat1fxxpv3r7mw
  text: 'Correction to the step record above: the count of changed files is 8, not 9. The list in that record is complete.'
  timestamp: 2026-10-12T15:33:20.267502+00:00
- actor: claude-code
  id: 01m4rc95pj3xbeeqv0p0wq80vs
  text: |-
    ### review — findings
    - evidence: `review sha 89c9ad3~1..89c9ad3`, 2 findings (2 confirmed, 2 refuted) — Sources/Marketplace/MarketplaceStore.swift:969, Tests/FoundationModelsExtrasTests/Telemetry/TelemetryDependencyTests.swift:162
    - next: /implement the 2 open items in the "Review Findings (2026-10-12 10:35)" section. The task stays in `review`.
  timestamp: 2026-10-12T15:39:12.466352+00:00
- actor: claude-code
  id: 01m4rc97bgegsjx8zqvgv6nzqn
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 8 files
    - test: green — swift test, 1033 passed
    - commit: 89c9ad3
    - review: findings — Sources/Marketplace/MarketplaceStore.swift:969, Tests/FoundationModelsExtrasTests/Telemetry/TelemetryDependencyTests.swift:162
  timestamp: 2026-10-12T15:39:14.160927+00:00
- actor: claude-code
  id: 01m4rcnnkm0z4shtt1698vbdyw
  text: |-
    Review findings done.
    - Finding 1 (duplication): new private actor helper `runTracedStep(named:atIndex:current:_:)` in MarketplaceStore.swift. It runs `MarketplaceTelemetry.traceStep` and maps a thrown error through `failureResult`. `checkHead` and `sync` call it; the two do/catch copies are gone. A check of MarketplaceStore.swift and MarketplaceTelemetry.swift found no other copied wrapper: `fetch` and `remoteHead` each forward one call to the shared `traceGitCall`, and `materialize` calls `traceStep` with no catch.
    - Finding 2 (invariant-propagation): TelemetryDependencyTests now reads EVERY entry of the `dependencies` list of a target (comments removed first, split at top-level commas, bracket-balanced). An entry is `.byName`, `.product(name:package:)`, or `.unread(text)` for a form that the read does not know. Each entry must be in an explicit allowlist: `marketplaceAllowlist` (telemetry API products + "FoundationModelsExtras", Yams, libgit2) and `coreAllowlist` (telemetry API products + Stencil, Yams, ULID, the 5 mlx-swift-lm products, HuggingFace, Tokenizers). The core target had the same gap (only a URL check for swift-otel), thus it gets the same allowlist test. New cases on a constructed manifest prove that a product of an unlisted telemetry package (OTLPExporter of swift-otlp-exporter), a non-API product of a listed package (InMemoryLogging of swift-log) and an entry with a `condition:` (unread form) each fail the check. The old `ProductDependency`, `telemetryProducts` and `productDependencies` helpers are deleted.
    - RED: with a stub read that gave no entries, 6 of the 11 suite tests failed. GREEN: 11 of 11 passed.
  timestamp: 2026-10-12T15:46:01.972829+00:00
- actor: claude-code
  id: 01m4rcnqk9rp3mxrc52a38xw38
  text: |-
    ### implement — changed
    - evidence: `swift test` exit 0: 1037 Swift Testing tests in 91 suites passed (11 known issues that were there before), 393 tests in 29 suites (MarketplaceTests) passed, 0 compiler warnings, 0 failures. 2 files: Sources/Marketplace/MarketplaceStore.swift, Tests/FoundationModelsExtrasTests/Telemetry/TelemetryDependencyTests.swift. Both findings are `- [x]`.
    - next: /review
  timestamp: 2026-10-12T15:46:04.009787+00:00
- actor: claude-code
  id: 01m4rcxs0fazawm9vsmgv0pgc5
  text: |-
    ### review — findings
    - evidence: `review sha 607883f~1..607883f`, 1 finding (1 confirmed, 2 refuted) — Tests/FoundationModelsExtrasTests/Telemetry/TelemetryDependencyTests.swift:53
    - next: /implement the 1 open item in the "Review Findings (2026-10-12 10:48)" section. The task stays in `review`.
  timestamp: 2026-10-12T15:50:27.599460+00:00
- actor: claude-code
  id: 01m4rcxwd7a95gs53eb0h7eq8v
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 2 files
    - test: green — swift test, 1037 passed
    - commit: 607883f
    - review: findings — Tests/FoundationModelsExtrasTests/Telemetry/TelemetryDependencyTests.swift:53
  timestamp: 2026-10-12T15:50:31.079589+00:00
- actor: claude-code
  id: 01m4rd79mdmsp4m99f00vcwasw
  text: |-
    Review finding (reuse) done.
    - The copy of the core target name was in `PackageLayoutTests` (target `MarketplaceTests`). That target and `FoundationModelsExtrasTests` both link `FixtureSupport`, thus the shared names now live in the new file `Tests/FixtureSupport/PackageManifest.swift`: `PackageManifest.path`, `coreTargetName`, `marketplaceTargetName`, `marketplaceSourcesPath`, `libgit2Product` and `tracingProduct`. `ManifestProduct` (name, package, `dependencyText`) gives the `.product(name:package:)` text that `PackageLayoutTests` reads.
    - Each other constant that this task added was checked: the manifest path, the marketplace target name, the libgit2 product, the tracing product and the "Marketplace" text in `marketplaceDependency` had copies in `PackageLayoutTests`; the "Sources/Marketplace" path had copies in `NoGitProcessTests`, `ModuleBoundaryTests` and `MarketplaceTelemetryTests`. All now read `PackageManifest`. In `TelemetryDependencyTests`, the Yams product was written two times (both allowlists) and once more in the fixture manifest; it is now one `yamsProduct`, and the fixture manifest writes the Yams and Logging entries from `dependencyText`. `TargetDependency.linking(_:)` makes a dependency from a `ManifestProduct`.
    - No copy of the swift-log/swift-metrics URLs, the otel marker, the bootstrap calls, the os markers or the other core allowlist products exists elsewhere in the test targets.
    - No new test: this is a refactor of test constants; the existing manifest tests in both suites cover the values.
  timestamp: 2026-10-12T15:55:39.533069+00:00
- actor: claude-code
  id: 01m4rd7cjcp39pcjs87wd42014
  text: |-
    ### implement — changed
    - evidence: `swift test` exit 0: 1037 Swift Testing tests in 91 suites passed (11 known issues that were there before), 393 tests in 29 suites (MarketplaceTests) passed, 0 failures, 0 compiler warnings (only the mlx-swift "missing creator for mutated node" line of the dependency build). 6 files: Tests/FixtureSupport/PackageManifest.swift (new), Tests/FoundationModelsExtrasTests/Telemetry/TelemetryDependencyTests.swift, Tests/MarketplaceTests/PackageLayoutTests.swift, Tests/MarketplaceTests/NoGitProcessTests.swift, Tests/MarketplaceTests/ModuleBoundaryTests.swift, Tests/MarketplaceTests/MarketplaceTelemetryTests.swift. The finding is `- [x]`.
    - next: /review
  timestamp: 2026-10-12T15:55:42.540277+00:00
- actor: claude-code
  id: 01m4rdedztarhre811z7qfdp66
  text: |-
    ### review — findings
    - evidence: `review sha 9f235ae~1..9f235ae`, 1 finding (1 confirmed, 1 refuted) — Tests/MarketplaceTests/PackageLayoutTests.swift:114
    - next: /implement the 1 open item in the "Review Findings (2026-10-12 10:57)" section. The task stays in `review`.
  timestamp: 2026-10-12T15:59:33.370404+00:00
- actor: claude-code
  id: 01m4rdefsgawzxjr1tjbx0qmzs
  text: |-
    ### finish iteration 3 — findings
    - implement: changed — 6 files
    - test: green — swift test, 1037 passed
    - commit: 9f235ae
    - review: findings — Tests/MarketplaceTests/PackageLayoutTests.swift:114
  timestamp: 2026-10-12T15:59:35.216331+00:00
- actor: claude-code
  id: 01m4rdxkd5c36eve6z7zqxqhtv
  text: |-
    Review finding (reuse, PackageLayoutTests.swift:114) done with a FULL sweep. I compared each function and helper of TelemetryDependencyTests, PackageLayoutTests, NoGitProcessTests, ModuleBoundaryTests and MarketplaceTelemetryTests.
    - Manifest reader: now `PackageManifest.text()` in Tests/FixtureSupport/PackageManifest.swift. `PackageLayoutTests.manifest()` and `TelemetryDependencyTests.manifestText()` are deleted. Both suites call the shared reader directly.
    - Target dependencies: both suites had a reader of the dependencies of one target. PackageLayoutTests split the manifest into target blocks (`targetDeclarations`, `targetDeclaration(named:in:)`, `targetMarkers`) and looked for the `.product(...)` text. TelemetryDependencyTests parsed the `dependencies` list (`listEntries`, `topLevelEntries`, `trimmed`, `dependency(of:)`, `TargetDependency`). There is now one copy: `PackageManifest.dependencies(ofTarget:)` and `dependencies(ofTarget:in:)`, plus the public `TargetDependency` enum (new file Tests/FixtureSupport/TargetDependency.swift). The `.product(...)` parse is now `TargetDependency.init(reading:)`. A missing target throws `FixtureError` because FixtureSupport does not link Testing and cannot use `#require`. PackageLayoutTests now compares `TargetDependency` values and does not do a text search. The block splitter is deleted.
    - Source reader: four copies read the Swift files under a folder: `TelemetryDependencyTests.librarySources`, `ModuleBoundaryTests.sourceTexts`, the inline enumerator in `MarketplaceTelemetryTests` and the inline `subpathsOfDirectory` walk in `NoGitProcessTests`. There is now one copy: `FixtureFile.swiftSources(under:) -> [SourceFile]` (new file Tests/FixtureSupport/SourceFile.swift). It gives paths relative to the package root, sorted. All four suites call it. The private `swiftExtension` and `swiftFileSuffix` constants are deleted.
    - The "Sources" constant of TelemetryDependencyTests is now `PackageManifest.sourcesPath`, and `marketplaceSourcesPath` is built from it.
    - Not in scope: GitTreeFileSourceTests and SnapshotWriterTests read temporary folders, not package sources, and only MarketplaceTests has them.
    - New tests: Tests/FoundationModelsExtrasTests/PackageManifestTests.swift (6 tests) cover the shared readers. RED: the build failed with "type 'PackageManifest' has no member 'text'/'dependencies'" and "type 'FixtureFile' has no member 'swiftSources'". GREEN: 6 of 6 passed.
  timestamp: 2026-10-12T16:07:50.437624+00:00
- actor: claude-code
  id: 01m4rdxpkp2m5fajqqrm7nb7k7
  text: |-
    ### implement — changed
    - evidence: `swift test` passed: 1043 Swift Testing tests in 92 suites (11 known issues, which were there before) and 393 tests in 29 suites (MarketplaceTests). 0 failures. 0 compiler warnings. The only warning is the mlx-swift "missing creator for mutated node" line of the dependency build. 9 files: Tests/FixtureSupport/PackageManifest.swift, Tests/FixtureSupport/TargetDependency.swift (new), Tests/FixtureSupport/SourceFile.swift (new), Tests/FoundationModelsExtrasTests/PackageManifestTests.swift (new), Tests/FoundationModelsExtrasTests/Telemetry/TelemetryDependencyTests.swift, Tests/MarketplaceTests/PackageLayoutTests.swift, Tests/MarketplaceTests/ModuleBoundaryTests.swift, Tests/MarketplaceTests/MarketplaceTelemetryTests.swift, Tests/MarketplaceTests/NoGitProcessTests.swift. The finding is `- [x]`.
    - next: /review
  timestamp: 2026-10-12T16:07:53.718808+00:00
depends_on:
- 01M4NYFFAQH23KD4E03AC35EK3
position_column: doing
position_ordinal: '80'
title: 'Marketplace telemetry: add the API dependencies, a vocabulary file, and spans and timers for passes, head checks and fetches'
---
## What

The `Marketplace` target has no telemetry. A slow or hung git fetch, or a pass that fails again and again, shows nothing. The target does not link swift-log, swift-metrics or swift-distributed-tracing: its dependencies (`Package.swift:303-312`) are `FoundationModelsExtras`, `Yams` and `libgit2` only.

Out of scope: `EventBroadcaster` (`Sources/Marketplace/EventBroadcaster.swift`) gets no queue metrics. It is a fan-out of events to subscribers, with no work task to time, and `AsyncStream` does not show its buffer count.

Approach:
- `Package.swift`: add `.product(name: "Logging", package: "swift-log")`, `.product(name: "Metrics", package: "swift-metrics")` and `.product(name: "Tracing", package: "swift-distributed-tracing")` to the `Marketplace` target, as API only. No backend, no `LoggingSystem.bootstrap`, no `MetricsSystem.bootstrap`. Add `TelemetryTestSupport` and `MetricsTestKit` to the `MarketplaceTests` test target (`:366`) for the tests.
- `Tests/FoundationModelsExtrasTests/Telemetry/TelemetryDependencyTests.swift` must still pass. Extend it so that it also checks the `Marketplace` target: API products only, no backend, no bootstrap.
- New vocabulary file `Sources/Marketplace/MarketplaceTelemetry.swift`. Each span name, attribute key, metric name and log metadata key of the target goes there, and each name starts with `Marketplace.`. No other file of the target has a telemetry string literal. Make the metric objects at call time.
- `Sources/Marketplace/MarketplaceStore.swift`: a span for each of `runPass(_:atIndex:)` (`:742`), `checkHead(remote:current:atIndex:)` (`:849`), `sync(remote:atIndex:force:)` (`:918`), `fetch(remote:revision:)` (`:1069`), `remoteHead(of:)` (`:1107`) and `materialize(remote:source:commit:)` (`:1131`). Attributes: `marketplace.id` (the display id), `pass.kind` and the outcome. Use `TracedCall` for `fetch` and `remoteHead`, so that a hung network call has an "enter" record.
- Timers of the fetch and of the head check. A Counter of passes by result: `up_to_date`, `updated` or `failed`. Take the result from the safe `MarketplaceEvent` cases (`checked`, `updateAvailable`, `updated`, `failed`; `Sources/Marketplace/MarketplaceEvent.swift:9-50`). Do not record the `error: String` of `MarketplaceEvent.failed` (`:49`) in a span, a log record or a metric; record `error.type` only.
- Never record a URL, a credential, a ref that a user typed, or a path.

## Acceptance Criteria
- [x] The `Marketplace` target links the logging, metrics and tracing API products, and `TelemetryDependencyTests` checks that it links no backend and calls no bootstrap.
- [x] `MarketplaceTelemetry.swift` holds each telemetry name of the target, and each name starts with `Marketplace.`.
- [x] Each pass opens a span with `marketplace.id`, `pass.kind` and the outcome, with child spans for the head check, the sync, the fetch, the remote head and the materialize step when they run.
- [x] Each fetch and each head check records one duration, and each pass adds one count with its result (`up_to_date`, `updated` or `failed`).
- [x] No span, log record or metric carries the `error: String` of `MarketplaceEvent.failed`.

## Tests
- [x] `Tests/MarketplaceTests/MarketplaceStoreTests.swift` (target `MarketplaceTests`): with `GitFixtureRepository` and `RecordingGitTransport` from `MarketplaceFixtures`, `W3CInMemoryTracer` and `MetricsTestKit` `TestMetrics`, test the span tree, the timers and the pass counter for a pass that is up to date, a pass that updates, and a pass that fails.
- [x] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the remote URL, a credential, the cache path and the `error` text of a failed pass.
- [x] `Tests/FoundationModelsExtrasTests/Telemetry/TelemetryDependencyTests.swift` covers the `Marketplace` target.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature

## Review Findings (2026-10-12 10:35)

> Scope: `review sha 89c9ad3~1..89c9ad3` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/Marketplace/MarketplaceStore.swift:969` `duplication/duplication` — The sync wrapper in sync(remote:atIndex:force:) repeats the shape of checkHead(remote:current:atIndex:). Both run a do block that returns a traceStep call, and both have a catch block that returns failureResult. This change added the traceStep wrapper to both, so the two copies now carry the same span-and-catch logic and can drift apart. Extract one private helper that takes the span name, the body, the marketplace index and the current sha. It runs the traceStep call and maps a thrown error through failureResult. Call it from checkHead and sync, and delete the two copies. Keep the body closures at each call site.
- [x] `Tests/FoundationModelsExtrasTests/Telemetry/TelemetryDependencyTests.swift:162` `completeness/invariant-propagation` — The guard that the Marketplace target links no telemetry backend only inspects products from the packages named in telemetryAPIProducts, or from a package whose name contains the otel marker. A backend product from any other telemetry package passes the check unseen, so the test does not prove what its title says. Check every product of the Marketplace target against the allowlist, not only the products that pass the package filter. Each linked product must equal the API product of its package, and a package outside telemetryAPIProducts should fail the test. Add a case for an unlisted telemetry package to lock this in.

## Review Findings (2026-10-12 10:48)

> Scope: `review sha 607883f~1..607883f` — reviewed the diffs only — lines this change added or modified. 2 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsExtrasTests/Telemetry/TelemetryDependencyTests.swift:53` `reuse/reuse` — The new coreTarget constant repeats the name of the core target, which another suite already defines. Two copies of one name can drift apart when the target is renamed. Share the target-name constant in one place, for example on FixtureFile or a shared fixture type, and use it from both suites. If the suites must stay separate, state why the copy is kept.

## Review Findings (2026-10-12 10:57)

> Scope: `review sha 9f235ae~1..9f235ae` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/MarketplaceTests/PackageLayoutTests.swift:114` `reuse/reuse` — The new body of `manifest()` reimplements `manifestText()` in TelemetryDependencyTests. Both read `PackageManifest.path` through `FixtureFile.text` and unwrap the result. Two copies of the manifest reader can drift apart. The reader belongs beside `PackageManifest` in FixtureSupport, which this change now shares for names. Move the reader into `PackageManifest` in Tests/FixtureSupport/PackageManifest.swift, for example as `static func text() throws -> String`. Have both `manifest()` and `manifestText()` call it, or delete the private copies and call the shared reader directly.
