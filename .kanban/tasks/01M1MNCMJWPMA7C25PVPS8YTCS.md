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

- **New** `Scripts/record-git-parity-snapshots.swift` — the recorder. Run it
  with `swift Scripts/record-git-parity-snapshots.swift` from the repository
  root. It holds the subprocess code that leaves the test target: it makes a
  temporary git repository, writes the ignore files, makes each probe path
  on disk, runs
  `git check-ignore --verbose --non-matching --stdin`, and writes the two
  snapshot files. Move the code out of `IgnoreGitParityTests.swift` rather
  than write it again. **Drain the two pipes at the same time**, or read the
  output with one pipe — do not repeat the sequential read.
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

`Package.swift` needs no change: the fixtures are under the `.copy("Fixtures")`
resource that is already declared, and `Scripts/` belongs to no target.

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
git run, that `Scripts/record-git-parity-snapshots.swift` makes it again,
and that a person reads the diff after a git upgrade. A snapshot that no one
can make again is a snapshot no one can trust.

## Acceptance Criteria

- [ ] `swift test` starts no `git` process. `GitParityHarness` is gone, and
      no test file holds `Process`, except the `extras-demo` harness in
      `ExtrasDemoIntegrationTests.swift`.
- [ ] No parity test carries an `.enabled(if:)` gate. Both run every time.
- [ ] The snapshots hold a verdict for every probe path of their suite.
- [ ] The verdicts in the snapshot equal the verdicts the git run gives
      today: after `swift Scripts/record-git-parity-snapshots.swift` runs a
      second time, `git status` reports no change to the two JSON files
      (`recordedOn` excepted, if it moves).
- [ ] The corpus test states no `isIgnored` and no `decidingLine` of its
      own. Those come from the snapshot.
- [ ] `swift build` and `swift test` are clean, with no warning.

## Tests

- [ ] Run `swift Scripts/record-git-parity-snapshots.swift`, then run it
      again. The second run leaves the two JSON files unchanged.
- [ ] Prove the snapshot really came from git, and is not a copy of what
      `IgnoreProcessor` already answers: check that the recorded values equal
      the `isIgnored` and `decidingLine` values that the `probes` table holds
      **now**, before you delete them. Report any path where they differ —
      such a path is a true parity failure that the gated test was hiding.
- [ ] Test: each verdict of `IgnoreProcessor` over the corpus equals the
      snapshot, in `isIgnored` and in the deciding line.
- [ ] Test: the combined `exclude + gitignore` verdicts equal their
      snapshot, in `isIgnored`, in the deciding line, and in the deciding
      source.
- [ ] Test: the suite fails if a snapshot file is absent or cannot be
      decoded. It must not pass in silence over a missing snapshot, which is
      the failure the `.enabled(if:)` gate had.
- [ ] Run `swift test --filter Ignore`. Expect all tests to pass, and expect
      no test to be skipped.
- [ ] Run the full `swift test`. Expect 0 failures, 0 warnings, 0 skipped.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.