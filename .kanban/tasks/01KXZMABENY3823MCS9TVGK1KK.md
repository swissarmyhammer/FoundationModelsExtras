---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kxzn3jkcgzvv5rc8n7t0ccfq
  text: |-
    Implemented via TDD. RED: 4 new tests in DotfolderStackTests (XDG absolute -> <xdg>/<name>/; unset/empty/relative -> ~/.config/<name>/) verified failing against the old ~/.<name> derivation. GREEN: DotfolderStack.init now resolves the nil-userDirectory case through a new private static xdgUserDirectory(name:environment:) — absolute XDG_CONFIG_HOME wins, else ~/.config/<name>/; no ~/.<name> path remains. Updated doc comments (type header, Source.user, name/userDirectory/environment params, isSafeDotfolderName, precondition message) and plan.md §3 (precedence line + the init comment example two lines above it, which also said ~/.myagent). Full suite: 114 tests in 12 suites, all pass.

    Surprise worth recording: the pipeline instruction "swift format -i -r Sources Tests" reformats the ENTIRE package from its committed 4-space indentation to swift-format's default 2-space (no .swift-format config exists anywhere up the tree) — a ~3300-line unrelated diff. I reverted that churn and kept the change scoped, matching the prevailing 4-space style. If the project intends swift format, it needs a .swift-format config with indentation: spaces 4 (or a one-time deliberate reformat commit).
  timestamp: 2026-07-20T11:38:14.508456+00:00
- actor: claude-code
  id: 01kxznc5ntwkm477p6c7fgcp36
  text: 'double-check verdict: REVISE with one Medium finding — isSafeDotfolderName accepted ".." (harmless under the old ".<name>" prefix, which turned it into "..."), but the new bare-name join derived $XDG_CONFIG_HOME/.. — the config directory''s parent. Fixed via TDD: added initTrapsWhenNameIsParentDirectoryReference (watched it fail), then tightened isSafeDotfolderName to also reject "..", and updated its doc, the init name-param doc, and the precondition message. Full suite: 115 tests in 12 suites, all pass.'
  timestamp: 2026-07-20T11:42:56.186176+00:00
position_column: done
position_ordinal: 8a80
title: Make DotfolderStack's user layer XDG-compliant ($XDG_CONFIG_HOME/<name>, default ~/.config/<name>)
---
## What

Replace the user layer's default derivation in `Sources/FoundationModelsExtras/DotfolderStack.swift` from the classic home dotfolder `~/.<name>/` to the XDG Base Directory location. Clean replacement — do NOT keep `~/.<name>` as a fallback or extra layer (decided with the user; nothing has shipped yet).

Current code (in `DotfolderStack.init`):

```swift
let resolvedUserDirectory =
    userDirectory
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".\(name)", isDirectory: true)
```

New behavior when `userDirectory == nil`:

1. Read `XDG_CONFIG_HOME` from the **injected `environment` dictionary** (the same seam already used for `<NAME>_DEFAULTS_DIR` — keeps this fully testable without real process state).
2. If it is set, non-empty, and **absolute** (leading `/`), the user layer roots at `<XDG_CONFIG_HOME>/<name>/`. Per the XDG Base Directory spec, a relative `XDG_CONFIG_HOME` is invalid and must be ignored.
3. Otherwise fall back to `FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/<name>", isDirectory: true)` — i.e. `~/.config/<name>/`.

Note the XDG path uses the bare `<name>` (no leading dot). The project layer stays `<workingDirectory>/.<name>/` and the `isSafeDotfolderName` precondition stays as-is (the name is still embedded as `.<name>` for the project layer and as a single path component under the config dir, so the same rules apply).

Doc updates required in the same file — the `~/.<name>/` convention is documented in several places: the type-level doc comment (`defaults < user (~/.<name>/) < project (<cwd>/.<name>/)`), the `Source.user` case doc, the `userDirectory:` parameter doc, and the `isSafeDotfolderName` doc's mention of the home directory. Also update `plan.md` §3's layer-precedence comment (`/// defaults < user (~/.<name>/) < project (<cwd>/.<name>/), in precedence order.`) to match.

No caller changes needed: `Examples/ExtrasDemo/Sources/extras-demo/DemoFixtures.swift` and all existing tests pass an explicit `userDirectory:`, which continues to override derivation entirely.

- [x] Write failing tests for XDG derivation (see Tests)
- [x] Change the user-layer derivation in `DotfolderStack.init`
- [x] Update doc comments in `DotfolderStack.swift`
- [x] Update `plan.md` §3 layer-precedence line

## Acceptance Criteria

- [x] With `userDirectory: nil` and `environment: ["XDG_CONFIG_HOME": "/abs/path"]`, the `.user` layer's `root` is `/abs/path/<name>/`
- [x] With `userDirectory: nil` and no (or empty) `XDG_CONFIG_HOME` in the injected environment, the `.user` layer's `root` is `<home>/.config/<name>/`
- [x] A relative `XDG_CONFIG_HOME` (e.g. `"relative/config"`) is ignored and falls back to `<home>/.config/<name>/`
- [x] An explicit `userDirectory:` argument still wins over all derivation (existing tests keep passing unchanged)
- [x] No code path derives `~/.<name>/` anymore; doc comments in `DotfolderStack.swift` and `plan.md` §3 describe the XDG layout
- [x] Constructing a stack still performs no file I/O

## Tests

- [x] Add tests to `Tests/FoundationModelsExtrasTests/DotfolderStackTests.swift` (construction does no I/O, so these assert on `stack.layers` roots directly): XDG_CONFIG_HOME set → `<xdg>/<name>/`; unset/empty → `<home>/.config/<name>/`; relative value → ignored, `<home>/.config/<name>/`
- [x] Run `swift test` — all tests pass, including the pre-existing `DotfolderStackTests` layer-order and override tests

## Workflow

- Use `/tdd` — write failing tests first, then implement to make them pass.