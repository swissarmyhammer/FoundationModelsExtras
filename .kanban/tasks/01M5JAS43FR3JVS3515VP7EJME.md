---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5jb0maaryeav6bd5yer0p16
  text: |-
    Diagnosis (research done). This is a toolchain bug, not something in this repo.

    - Toolchain: Apple Swift 6.4 (swiftlang-6.4.0.34.1), Xcode 27.1 (27A9275). The default build system is now Swift Build (`.build/out/...` layout). `--build-system native` is deprecated.
    - Reproduced on an incremental `swift build` in this repo: `warning: missing creator for mutated node: ('.../.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')`.
    - mlx-swift 0.32.3 (the latest tag, which mlx-swift-lm@stable resolves) declares no `resources:` on `Cmlx`. Swift Build compiles the `.metal` sources in `Source/Cmlx` into `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`. The bundle has no `Contents/MacOS`, and still some task declares it as a mutated node.
    - Minimal clean repro outside this repo (scratchpad `metalrepro`): a tools-6.2 package with one C target that holds a single `add.metal` file, plus an executable that depends on it. A clean `swift build` prints the same warning for `MetalRepro_CShader.bundle/Contents/MacOS`, and every rebuild prints it again.
      - The same package with `--build-system native`: no warning (native does not compile .metal at all).
      - The same package with the .metal file replaced by a `.copy("data.txt")` resource: clean rebuild, no warning. So the trigger is Swift Build's metal-to-metallib resource-bundle path, not resource bundles in general and not any manifest of ours.
    - Web search found no known SwiftPM/swift-build issue for the metal case. A similar Xcode 10 new-build-system warning existed for Core Data model codegen in resource bundles.

    What did not work, or is not legitimate: no change to Package.swift can remove it. This repo cannot pick the build system in its manifest. Excluding the .metal sources would have to happen in mlx-swift and would break the GPU kernels. Filtering the warning is forbidden.
  timestamp: 2026-10-22T17:37:19.178800+00:00
- actor: claude-code
  id: 01m5jb0qhm0hfk2tn7tykq9ak7
  text: |-
    ### implement — stuck
    - evidence: no repo change. Swift 6.4 / Xcode 27.1 Swift Build prints "missing creator for mutated node .../<pkg>_<target>.bundle/Contents/MacOS" for any target that holds a .metal source. Minimal repro (one C target + one add.metal) shows it on a clean build. The native build system and a plain .copy resource do not show it. The cause sits in the toolchain (swift-build), and mlx-swift only triggers it.
    - next: a human must decide. Option (a): file a swiftlang/swift-build issue with the minimal repro and accept the warning until a toolchain fix ships (tracked, not suppressed). Option (b): change the subtask "zero warnings" for this toolchain warning. Forking mlx-swift to drop its .metal sources is not viable, because the GPU kernels need default.metallib.
  timestamp: 2026-10-22T17:37:22.484218+00:00
- actor: claude-code
  id: 01m5jb1629kxpt7hba3ez47rea
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — no repo change; cause is the Swift 6.4 / Xcode 27.1 Swift Build system: any target with a `.metal` resource gets "missing creator for mutated node …bundle/Contents/MacOS" (reproduced in a minimal scratch package; absent with --build-system native or a plain .copy resource). Package.swift cannot select the build system; mlx-swift needs its shaders.
    - test: not run
    - commit: none
    - review: not run
    - Human decision needed: (1) file an issue on swiftlang/swift-build with the minimal repro and accept the warning until a toolchain fix, or (2) relax this card's "zero warnings" subtask for this one toolchain warning.
  timestamp: 2026-10-22T17:37:37.353220+00:00
- actor: claude-code
  id: 01m5jdftw7k52sps3atftyk2f2
  text: |-
    ### Resolution — user decision 2026-10-22: allow the warning
    The user allows the Swift Build "missing creator for mutated node: (…/mlx-swift_Cmlx.bundle/Contents/MacOS)" warning. It is a toolchain warning (Swift 6.4 / Xcode 27.1 Swift Build, triggered by any `.metal` resource), not from this repo's code, and does not count against "zero warnings". No code change. Closed by user decision, not by review (no code to review, no open findings).
  timestamp: 2026-10-22T18:20:34.567296+00:00
position_column: done
position_ordinal: ffc280
title: 'swift test: SwiftPM prints "missing creator for mutated node" for the mlx-swift_Cmlx bundle'
---
Found while working ^tmmhe2e. Every `swift test` build in /Users/wballard/github/swissarmyhammer/FoundationModelsExtras prints this build-system warning before the tests run:

`warning: missing creator for mutated node: ('/Users/wballard/github/swissarmyhammer/FoundationModelsExtras/.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')`

It comes from the SwiftPM build graph for the mlx-swift `Cmlx` resource bundle, not from a source file. Find the cause (the package manifest, the mlx-swift dependency version, or the SwiftPM toolchain) and remove it so the build output has zero warnings.

## Subtasks
- [ ] Find why SwiftPM reports a missing creator for the `mlx-swift_Cmlx.bundle/Contents/MacOS` node
- [ ] Remove the cause so `swift test` prints zero warnings