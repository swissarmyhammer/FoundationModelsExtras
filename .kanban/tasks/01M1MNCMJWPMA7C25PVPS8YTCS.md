---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1mnjpmsxf1989bs3padpk8x
  text: |-
    Picked up. Research notes.

    - `GitParityHarness` lives at the end of `Tests/FoundationModelsExtrasTests/IgnoreGitParityTests.swift` (about 210 lines). Two suites use it: `IgnoreGitParityTests` (test 2) and `IgnoreProcessorCombinationGitParityTests`.
    - The deadlock the card names is in `runCheckIgnore`: it calls `readDataToEndOfFile()` on stdout, then on stderr, one after the other. The recorder must drain both at the same time.
    - `materializeRepo` uses `canonicalize(_:)` from `Tests/FoundationModelsExtrasTests/TestSupport.swift`. The recorder is a standalone script, so it needs its own copy of that `realpath(3)` helper.
    - Source names: git reports `.gitignore` and `.git/info/exclude`. The corpus test compares the deciding LINE only, so `IgnoreProcessor(contentsOf: gitignore.txt)` (source `gitignore.txt`) is still correct there. The combination test compares the SOURCE too, so it must keep building its processors with `IgnoreProcessor(string:source:)` and state the two git source names.
    - The probe path list stays in the test (`probes`), and the recorder holds its own copy. The acceptance criterion "the snapshots hold a verdict for every probe path" is the guard against the two drifting.
    - Validator rules read before editing: swiftlint `no_magic_numbers` reports an unnamed numeric literal in a test file too. Deleting the hand-written `decidingLine:` integers removes about 20 of them.
  timestamp: 2026-09-03T22:17:38.713101+00:00
- actor: claude-code
  id: 01m1mnszaxwgf7bmef8cm745s7
  text: |-
    Verification the card asks for, done BEFORE the hand-written values are deleted.

    Recorded with `git version 2.55.0` on 2026-09-03, then compared every recorded verdict against the `isIgnored` and `decidingLine` values the `probes` table holds today.

    Result: all 40 corpus probes agree, in `isIgnored` and in the deciding line. No path differs, so the gated test was hiding no parity failure.

    Spot checks of the recorded provenance, which show the snapshot really came from git and is not a copy of what `IgnoreProcessor` answers:
    - `escapedspace ` -> `.gitignore:12:escapedspace\ ` (the escaped trailing space, quoted by git itself)
    - `digit5.txt` -> `.gitignore:34:digit[[:digit:]].txt`
    - `keep.log` -> not ignored, `.gitignore:16:!keep.log` — git names the negating rule as the deciding line
    - `sub/build/x.bin` -> `.gitignore:22:build/`

    The 4 combination probes agree as well:
    - `debug.log` -> ignored, `.git/info/exclude:1:*.log`
    - `build/x.o` -> ignored, `.git/info/exclude:2:build/`
    - `important.log` -> NOT ignored, `.gitignore:1:!important.log` (the higher-precedence layer wins)
    - `readme.md` -> not ignored, no rule

    The new snapshot test is STRICTER than the old git test. The old one wrote `if let gitLine = git.line { ... }`, so it never checked the paths where git reports no rule. The snapshot test compares the deciding line in both directions, `nil` included.
  timestamp: 2026-09-03T22:21:36.989584+00:00
- actor: claude-code
  id: 01m1mp3gwh2224ckgjkhdzx8r5
  text: |-
    Implementation landed.

    Shape:
    - `Scripts/record-git-parity-snapshots.swift` holds every line of subprocess code that left the test target. It is data-driven: one `SnapshotSuite` row per suite states the ignore fixtures, the probe paths and the snapshot it writes.
    - The deadlock is gone by construction, not by care. The run holds exactly ONE pipe: standard output. Standard input is a file the recorder writes the probe paths into, and standard error is a file the run reads back afterwards. There is no second pipe to fill while the first is being read, so no output size can block the run.
    - `Tests/FoundationModelsExtrasTests/IgnoreParityFixture.swift` is the one owner of fixture loading for both suites. Each loader returns a `Result`, so a suite holds it in a `static let`, loads once, and still surfaces a missing or undecodable file as a thrown test failure — never a crash, and never a quiet pass. `GitVerdictSnapshot.expectCoverage(of:)` carries the probe-coverage and provenance checks both suites need, with `sourceLocation` so a failure is reported at the calling test.
    - Both suites lost their `.enabled(if:)` gate. Both run every time.

    RED evidence — each new test was made to fail on purpose before it was accepted:
    1. One recorded corpus line changed from 34 to 33: `verdictMatchesRecordedGitVerdict` fails on `digit5.txt`.
    2. The combination snapshot removed: 5 issues, `could not read the fixture at ...`. It fails; it does not skip.
    3. The combination snapshot replaced with text that is not JSON: 5 issues, `could not decode the git-verdict snapshot at ...`.
    4. A probe path added that the recorder never saw: `snapshotCoversEveryProbe` fails, and the probe test fails with `the snapshot holds no verdict for probe ...`.
    5. One verdict removed from the combination snapshot: `snapshotCoversEveryProbe` fails, reported at the caller's line.

    What did NOT work, for the next agent: the first plan was to drain two pipes at once from a `DispatchQueue`, which needs a mutable capture in a `@Sendable` closure and an `@unchecked Sendable` box to hold it. The single-pipe shape needs neither, and the card sanctions it.

    Idempotency: the recorder ran three times over the run. Every run left both JSON files byte-identical (SHA-256 unchanged, `git status` reports no modification).
  timestamp: 2026-09-03T22:26:49.873408+00:00
- actor: claude-code
  id: 01m1mp3qcdaz1d9mx8qft6p733
  text: |-
    ### implement — changed
    - evidence: 8 files — Scripts/record-git-parity-snapshots.swift (new), Tests/FoundationModelsExtrasTests/IgnoreParityFixture.swift (new), Tests/FoundationModelsExtrasTests/Fixtures/ignore-corpus/git-verdicts.json (new), Tests/FoundationModelsExtrasTests/Fixtures/ignore-combination/{exclude.txt,gitignore.txt,git-verdicts.json} (new), Tests/FoundationModelsExtrasTests/IgnoreGitParityTests.swift (397 -> 158 lines, GitParityHarness deleted), Tests/FoundationModelsExtrasTests/IgnoreProcessorCombinationGitParityTests.swift. `swift build`: 0 warnings, 0 errors. `swift test --filter Ignore`: 77 tests in 7 suites passed, 0 skipped. `swift test`: 5 targets, 94 + 34 + 44 + 22 + 259 = 453 tests passed, 0 failures, 0 warnings, 0 skipped. Recorder run twice more: both JSON files byte-identical. Package.swift unchanged, as the card predicted.
    - next: /review
  timestamp: 2026-09-03T22:26:56.525302+00:00
- actor: claude-code
  id: 01m1mpn1bdtjvwkx5b3eb7pfq9
  text: |
    ### review — findings
    - evidence: 8 findings (8 confirmed, 0 refuted) from `review sha HEAD~1..HEAD` — Scripts/record-git-parity-snapshots.swift:151, :548, :568, :596; Tests/FoundationModelsExtrasTests/IgnoreParityFixture.swift:12, :39, :90, :147
    - next: fix every item in the `## Review Findings (2026-09-03 17:29)` checklist, then review again. Task stays in `review`.
  timestamp: 2026-09-03T22:36:23.789705+00:00
- actor: claude-code
  id: 01m1mpntp5bg6q6ekw020j1e88
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 8 files; all 40 corpus probes and all 4 combination probes matched the hand-written expectations, so the gated test hid no parity failure
    - test: green — `swift package clean && swift test`, 259 tests, 23 suites, 0 failed, 0 skipped, 0 warnings; no git process and no gate left in Tests/
    - commit: 912a67e test(ignore): add git parity snapshot fixtures and script
    - review: findings — 8 confirmed: Scripts/record-git-parity-snapshots.swift:151,548,568,596; Tests/FoundationModelsExtrasTests/IgnoreParityFixture.swift:12,39,90,147
    - next: iteration 2 works the 8 findings — 5 reuse (the recorder and the test fixture each hold their own copy of GitVerdict, GitVerdictSnapshot, the error wrapper, the fixture reader, and canonicalize), 2 print() in the recorder, 1 mutable accumulator
  timestamp: 2026-09-03T22:36:49.733881+00:00
- actor: claude-code
  id: 01m1mpx366zzdpn70njca3x517
  text: |-
    Iteration 2 picked up. Research for the 8 findings.

    Cause of the 5 `reuse/reuse` findings: `Scripts/record-git-parity-snapshots.swift` is a standalone `swift <file>` script, so it cannot import a SwiftPM target. That is why `GitVerdict`, `GitVerdictSnapshot`, the error wrapper, the fixture reader and `canonicalize()` are each written twice.

    Plan — the structural fix the card sanctions:
    - New plain library target `FixtureSupport` at `Tests/FixtureSupport/`. It owns ONE copy of `canonicalize(_:)`, the package-root lookup for checked-in fixtures, the fixture text reader, `GitVerdict`, `GitVerdictSnapshot`, and the `IgnoreParitySuite` table (fixture paths, layer names, probe paths, snapshot path).
    - The recorder becomes an executable target `record-git-parity-snapshots` at `Scripts/RecordGitParitySnapshots/`, depending on `FixtureSupport`. A person runs `swift run record-git-parity-snapshots`.
    - `FoundationModelsExtrasTests` gains a dependency on `FixtureSupport`; `Tests/FoundationModelsExtrasTests/TestSupport.swift` (its own `canonicalize`) is deleted, and `IgnoreParityFixture.swift` keeps only the test-facing conveniences — the `Result`-returning processor loader and the `expectCoverage` extension that needs `Testing`.

    Why not extend the existing `Tests/TestSupport` target: `FoundationModelsExtrasTests` already declares its own internal `enum PackageRootValidation`, and `Tests/TestSupport` declares a public one with a different member set. Importing that module into the test target would put two same-named types in scope. A new target with no colliding names avoids the question.

    The probe-path lists are duplicated the same way (recorder `corpusProbePaths` vs test `probes`). Once the recorder can import, that copy has no reason to exist either, so the suite table moves to `FixtureSupport` and both sides read it.

    The 2 `print(...)` findings: the recorder writes progress to standard error through the same `FileHandle.standardError` path the failure branch already uses, so no `print` remains anywhere in the file.

    No README or docs page names the script; only the two suite doc comments do. Both get the new command.
  timestamp: 2026-09-03T22:40:47.814512+00:00
- actor: claude-code
  id: 01m1mr0f31je744kxe7zzfp8kb
  text: |-
    Iteration 2 landed. All 8 findings answered at the cause.

    The structural change the 5 `reuse/reuse` findings needed:

    - `Tests/FixtureSupport/` is a new plain library target. It owns ONE copy of each declaration that was written twice: `URL.canonicalDirectory` (was `canonicalize`), `FixtureFile.text` (was `readFixture` + `loadText`), `FixtureError` (was `RecorderError` + `LoadError`), `GitVerdict`, `GitVerdictSnapshot`, and the `IgnoreParitySuite` table.
    - `Scripts/RecordGitParitySnapshots/` is the executable target `record-git-parity-snapshots`, which depends on `FixtureSupport`. Run it with `swift run record-git-parity-snapshots`. Verified from the package root AND from `/` with `--package-path`: both leave the two JSON files byte-identical.
    - `FoundationModelsExtrasTests` depends on `FixtureSupport` too. `Tests/FoundationModelsExtrasTests/TestSupport.swift` is deleted; its `canonicalize` moved to the shared target.

    Two decisions a later agent should not re-litigate:

    1. `canonicalize` became `extension URL { var canonicalDirectory }`, not a top-level `func`. `swift/immutability` states "A function belongs to a type. A top-level `func` carries no namespace". Moving the duplicated function into a new module would have written that DON'T into the diff. That is why 6 test files changed: 8 call sites moved from `canonicalize(x)` to `x.canonicalDirectory`.
    2. The shared target is NOT the existing `Tests/TestSupport`. `FoundationModelsExtrasTests` declares its own internal `enum PackageRootValidation`, and `Tests/TestSupport` declares a public one with a different member set. Importing that module into the test target would put two same-named types in scope. `FixtureSupport` shares no name with anything in the test target.

    Beyond the named findings, the same cause was removed everywhere it stood in the two files:

    - The probe-path lists were a sixth copy the review did not name (recorder `corpusProbePaths` vs test `probes`). Both sides now read `IgnoreParitySuite.corpus` / `.combination`, which also owns the fixture paths, the snapshot path, and the two source names `.gitignore` / `.git/info/exclude`.
    - `parseCheckIgnore` held a second `var` accumulator that the `swift/immutability` finding did not name. It is now `split().map(parse(line:))` folded with `Dictionary(_:uniquingKeysWith:)`.
    - `var data = try encoder.encode(...)` then `append` became `let data = try encoder.encode(...) + Data("\n".utf8)`.
    - Both `print(...)` calls are gone. `Report.write` sends progress AND failures to standard error, so the tool writes nothing at all to standard out.
    - The recorder is `@main` with no top-level code, so no global is main-actor-isolated and no function reaches across that boundary.

    One new named constant was needed after the fact: `swiftlint no_magic_numbers` flagged `prefixFields[2]`. The parser now reads the pattern as `prefixFields.last`, which is also what `maxSplits` is for — the pattern may hold colons and must stay whole.

    Verification, run against a `swift package clean` tree:
    - `swift build`: Build complete, 0 warnings, 0 errors.
    - `swift test --filter Ignore`: 77 tests in 7 suites passed, 0 skipped.
    - `swift test`: 94 + 34 + 44 + 22 + 259 = 453 tests, 0 failures, 0 warnings, 0 skipped.
    - `swift run record-git-parity-snapshots` twice: SHA-256 of both JSON files unchanged from the baseline (`ea27796e...` corpus, `99e77dbb...` combination); `git status` reports no change under `Tests/.../Fixtures`.
    - swiftlint over the project's own rule roster (the 12 `disallowed-constructs-swift` rules plus `function_body_length`, `closure_body_length`, `no_magic_numbers`): 0 violations in every file this change authored.
    - `Process()` appears in one test file only, `ExtrasDemoIntegrationTests.swift`. No `.enabled(if:)` and no `GitParityHarness` anywhere.

    No README or docs page named the script, so only the two suite doc comments and `Package.swift` needed the new command. Both now say `swift run record-git-parity-snapshots`.
  timestamp: 2026-09-03T23:00:06.881767+00:00
- actor: claude-code
  id: 01m1mr0pa7wmf1ntxp5vvar45k
  text: |-
    ### implement — changed
    - evidence: 17 files — new Tests/FixtureSupport/{URL+CanonicalDirectory,FixtureFile,GitVerdictSnapshot,IgnoreParitySuite}.swift; new Scripts/RecordGitParitySnapshots/{RecordGitParitySnapshots,Subprocess,ScratchRepository,GitCheckIgnore}.swift; deleted Scripts/record-git-parity-snapshots.swift and Tests/FoundationModelsExtrasTests/TestSupport.swift; changed Package.swift, Tests/FoundationModelsExtrasTests/{IgnoreParityFixture,IgnoreGitParityTests,IgnoreProcessorCombinationGitParityTests,AgentsMdTests,DotfolderLoaderTests,DotfolderStackTests,IgnoreProcessorTests,LayeredYAMLDocumentTests,UntrustedRenderingTests}.swift. All 8 findings checked. `swift build`: 0 warnings. `swift test --filter Ignore`: 77 tests, 0 skipped. `swift test` on a cleaned tree: 453 tests, 0 failures, 0 warnings, 0 skipped. Recorder re-run twice: both JSON snapshots byte-identical (SHA-256 unchanged).
    - next: /review
  timestamp: 2026-09-03T23:00:14.279251+00:00
position_column: doing
position_ordinal: '80'
title: Snapshot the git parity verdicts; stop running git in the test suite
---
## What

Two test suites run `git` as a subprocess to prove that `IgnoreProcessor`
agrees with `git check-ignore`. Running git at test time is the wrong shape:

- It makes the suite depend on a tool that can be absent, so both tests carry
  a `.enabled(if: GitParityHarness.isGitAvailable())` gate. A gated test that
  does not run proves nothing, and no one sees the skip.
- It brings about 210 lines of subprocess plumbing (`GitParityHarness`) into
  the unit-test target, together with a latent deadlock: the harness reads
  its two pipes one after the other, which blocks when the output is larger
  than the pipe buffer.
- The result of a run does not change from day to day. git gives the same
  answer each time for the same fixture.

**Record the git verdicts one time, keep them in the repository, and compare
against them.** The parity claim stays as strong, and the suite stops
starting a process.

This also makes one source of truth. Today the corpus test holds
hand-written `isIgnored` and `decidingLine` values in its `probes` table,
which say the same thing the git run says. After this change the snapshot is
the only statement of what git answers.

### Files

- **New** the recorder. It holds the subprocess code that leaves the test
  target: it makes a temporary git repository, writes the ignore files, makes
  each probe path on disk, runs
  `git check-ignore --verbose --non-matching --stdin`, and writes the two
  snapshot files. Move the code out of `IgnoreGitParityTests.swift` rather
  than write it again. **Drain the two pipes at the same time**, or read the
  output with one pipe — do not repeat the sequential read.

  It first landed as `Scripts/record-git-parity-snapshots.swift`, run with
  `swift Scripts/record-git-parity-snapshots.swift`. Review found that a
  standalone script cannot import a SwiftPM target, which forced five copied
  declarations, so the recorder is now the SwiftPM executable target
  `record-git-parity-snapshots` at `Scripts/RecordGitParitySnapshots/`. Run
  it with `swift run record-git-parity-snapshots`.
- **New** `Tests/FixtureSupport/` — a plain library target both the test
  target and the recorder depend on. It owns the ONE copy of
  `URL.canonicalDirectory`, the checked-in fixture reader, `FixtureError`,
  `GitVerdict`, `GitVerdictSnapshot`, and the `IgnoreParitySuite` table that
  names each suite's ignore fixtures, probe paths and snapshot.
- **New** `Tests/FoundationModelsExtrasTests/Fixtures/ignore-corpus/git-verdicts.json`
- **New** `Tests/FoundationModelsExtrasTests/Fixtures/ignore-combination/exclude.txt`,
  `.../gitignore.txt`, and `.../git-verdicts.json` — the combination test
  holds its two ignore files as inline Swift strings today. Move them to
  fixture files, so the recorder and the test read the same bytes and cannot
  drift.
- **Changed** `Tests/FoundationModelsExtrasTests/IgnoreGitParityTests.swift`
  — delete `GitParityHarness` and the git test. The remaining test reads the
  snapshot and checks each verdict of `IgnoreProcessor` against it. The
  `probes` table keeps only the path list; `isIgnored` and `decidingLine`
  come from the snapshot.
- **Changed**
  `Tests/FoundationModelsExtrasTests/IgnoreProcessorCombinationGitParityTests.swift`
  — same change, against its own snapshot. No gate, and no subprocess.

`Package.swift` gains the `FixtureSupport` library target and the
`record-git-parity-snapshots` executable target. The fixtures stay under the
`.copy("Fixtures")` resource that is already declared.

### The snapshot format

One JSON file for each suite. It records what git said, and which git said
it:

```json
{
  "recordedWith": "git version 2.55.0",
  "recordedOn": "2026-09-03",
  "verdicts": [
    { "path": "digit5.txt", "isIgnored": true,
      "source": ".gitignore", "line": 34, "pattern": "digit[[:digit:]].txt" },
    { "path": "digitA.txt", "isIgnored": false }
  ]
}
```

`source`, `line`, and `pattern` are absent when git reports no matching rule
(its `::` output). Sort the array by `path`, and write the file with sorted
keys, so a later recording gives a diff that a person can read.

Write in the doc comment of each suite that the snapshot comes from a real
git run, that `swift run record-git-parity-snapshots` makes it again, and
that a person reads the diff after a git upgrade. A snapshot that no one can
make again is a snapshot no one can trust.

## Acceptance Criteria

- [x] `swift test` starts no `git` process. `GitParityHarness` is gone, and
      no test file holds `Process`, except the `extras-demo` harness in
      `ExtrasDemoIntegrationTests.swift`.
- [x] No parity test carries an `.enabled(if:)` gate. Both run every time.
- [x] The snapshots hold a verdict for every probe path of their suite.
- [x] The verdicts in the snapshot equal the verdicts the git run gives
      today: after `swift run record-git-parity-snapshots` runs a second
      time, `git status` reports no change to the two JSON files
      (`recordedOn` excepted, if it moves).
- [x] The corpus test states no `isIgnored` and no `decidingLine` of its
      own. Those come from the snapshot.
- [x] `swift build` and `swift test` are clean, with no warning.

## Tests

- [x] Run `swift run record-git-parity-snapshots`, then run it again. The
      second run leaves the two JSON files unchanged.
- [x] Prove the snapshot really came from git, and is not a copy of what
      `IgnoreProcessor` already answers: check that the recorded values equal
      the `isIgnored` and `decidingLine` values that the `probes` table holds
      **now**, before you delete them. Report any path where they differ —
      such a path is a true parity failure that the gated test was hiding.
- [x] Test: each verdict of `IgnoreProcessor` over the corpus equals the
      snapshot, in `isIgnored` and in the deciding line.
- [x] Test: the combined `exclude + gitignore` verdicts equal their
      snapshot, in `isIgnored`, in the deciding line, and in the deciding
      source.
- [x] Test: the suite fails if a snapshot file is absent or cannot be
      decoded. It must not pass in silence over a missing snapshot, which is
      the failure the `.enabled(if:)` gate had.
- [x] Run `swift test --filter Ignore`. Expect all tests to pass, and expect
      no test to be skipped.
- [x] Run the full `swift test`. Expect 0 failures, 0 warnings, 0 skipped.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-03 17:29)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 16 not reviewed.

> 12 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 12 file(s)

> 4 file(s) not reviewed — no validator matched:
> - `Tests/FoundationModelsExtrasTests/Fixtures/ignore-combination/exclude.txt` — no validator matches this file
> - `Tests/FoundationModelsExtrasTests/Fixtures/ignore-combination/git-verdicts.json` — no validator matches this file
> - `Tests/FoundationModelsExtrasTests/Fixtures/ignore-combination/gitignore.txt` — no validator matches this file
> - `Tests/FoundationModelsExtrasTests/Fixtures/ignore-corpus/git-verdicts.json` — no validator matches this file

- [x] `Scripts/record-git-parity-snapshots.swift:151` `reuse/reuse` — Reimplements `canonicalize()` function that already exists in TestSupport.swift:20 (1.00 similarity). The function resolves symlinks and firmlinks using realpath(3) — a shared capability that should be called rather than duplicated. Either refactor the script to import and reuse TestSupport.canonicalize(), or if architectural constraints prevent importing test utilities, document why the separate implementation is necessary.
- [x] `Scripts/record-git-parity-snapshots.swift:548` `swift/immutability` — Mutable accumulator in a collection transformation should be replaced with functional operations. A reader must walk the loop body to learn the final value, whereas `map` and `sorted` make the transformation explicit. Replace with `let verdicts = try suite.probePaths.map { probePath -> GitVerdict in guard let verdict = verdictsByPath[probePath] else { throw RecorderError(message: "git reported no result at all for probe \(probePath) of \(suite.name)") }; return verdict }.sorted { $0.path < $1.path }`.
- [x] `Scripts/record-git-parity-snapshots.swift:568` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `Scripts/record-git-parity-snapshots.swift:596` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `Tests/FoundationModelsExtrasTests/IgnoreParityFixture.swift:12` `reuse/reuse` — Defines `GitVerdict` struct that duplicates the same struct from Scripts/record-git-parity-snapshots.swift (0.96 similarity). Both represent git verdict data — the same domain, same data structure. Maintaining two copies invites divergence and makes coordinated updates difficult. Define `GitVerdict` once in a shared location (e.g., in the main library FoundationModelsExtras) with `Codable, Sendable` conformance, then use it in both the script and test fixture. The fixture version's `CustomStringConvertible` implementation can be added via extension if needed for testing.
- [x] `Tests/FoundationModelsExtrasTests/IgnoreParityFixture.swift:39` `reuse/reuse` — Defines `GitVerdictSnapshot` struct that duplicates the same struct from Scripts/record-git-parity-snapshots.swift. Both represent snapshot metadata and verdict arrays — same domain, same contract. The fixture version adds testing helper methods, but the core struct should not be duplicated. Define a single `GitVerdictSnapshot` struct in a shared location with `Codable, Sendable` conformance. Move test-specific helper methods into an extension in IgnoreParityFixture, keeping the base struct separate from test conveniences.
- [x] `Tests/FoundationModelsExtrasTests/IgnoreParityFixture.swift:90` `reuse/reuse` — Defines `LoadError` struct that duplicates `RecorderError` from Scripts/record-git-parity-snapshots.swift (0.87 similarity). Both are simple error wrappers with a message field and CustomStringConvertible conformance — the same error pattern in the same project. Unify error handling by moving the error type to a shared location or reusing one. If the script cannot import test utilities due to architectural constraints, consider defining the error type in the main library and importing it in both locations.
- [x] `Tests/FoundationModelsExtrasTests/IgnoreParityFixture.swift:147` `reuse/reuse` — Implements `loadText()` which duplicates the core logic of `readFixture()` from Scripts/record-git-parity-snapshots.swift (0.90 similarity). Both functions read fixture files as UTF-8 text. The only material difference is error handling strategy (Result wrapping vs. throwing), which could be factored out rather than duplicating the file-reading operation. Consider refactoring to share the core file-reading logic. Either: (1) generalize readFixture to return Result, or (2) have loadText internally call readFixture with try/catch wrapping. This requires either moving readFixture to a shared module or making it importable by the test fixtures.
