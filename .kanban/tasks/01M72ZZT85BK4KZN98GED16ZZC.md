---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m731t8ptq82pveqjfgkvhxhc
  text: 'Research: no Security framework use exists in Sources yet. The error style follows HubModelLoaderError (Error, Equatable, LocalizedError with errorDescription). The public surface test file uses a plain import, so a test that names the new types there proves they are public. The build shows warnings from the mlx-swift checkout (C++17 extension); these come from a dependency and are not new. REFERENCE.md has "## Tool hosting: `ToolContext` and `RunPlane`" before "## Tests"; the new section goes after it.'
  timestamp: 2026-11-10T15:39:20.666557+00:00
- actor: claude-code
  id: 01m7323wvxt9pa3prt4gzg3ha7
  text: |-
    ### implement — changed
    - evidence: new Sources/FoundationModelsExtras/Hosting/ToolMode.swift (ToolMode, SandboxProbe with .live and .fixed, ToolModeError with LocalizedError, validate(probe:) throws(ToolModeError)); new Tests/FoundationModelsExtrasTests/Hosting/ToolModeTests.swift; one test added to ToolHostingPublicSurfaceTests.swift; docs/REFERENCE.md section "Tool modes: `ToolMode`"; docs/GUIDE.md section "Checking the tool mode". RED: build failed with "cannot find 'ToolMode' in scope". GREEN: `swift test --filter ToolMode` 11 tests in 2 suites passed; `swift test --filter ToolHostingPublicSurface` 16 tests passed. No new warnings (only the existing mlx-swift C++17 warnings). Package.swift is not changed.
    - note: SandboxProbe.live returns false when the entitlement is absent, and uses APP_SANDBOX_CONTAINER_ID only when SecTaskCreateFromSelf fails or SecTaskCopyValueForEntitlement sets an error.
    - next: /review
  timestamp: 2026-11-10T15:44:36.221226+00:00
position_column: doing
position_ordinal: '80'
title: 'EXTRAS-12: ToolMode (open, sandboxed) and the check that refuses open mode in the App Sandbox'
---
## What
EXTRAS-12 (spec: `TestudoApp/features/packages/foundationmodels-extras.md`, decisions D128 (d), D131, D73, D174). This is the root of the mode changes. MT-15 (Multitool), SK-7 (Skills), ACPA-19 (ACPAgent) and APP-19 (TestudoApp) use this type. MacControl and AppleApps use it later.

Add one public mode type and one shared check to the core `FoundationModelsExtras` library target. Do not add a new target or product (D73). The rules work (the hard check, Seatbelt) is not in this task (D174).

Create `Sources/FoundationModelsExtras/Hosting/ToolMode.swift`:
- [x] `public enum ToolMode: String, Sendable, Codable, CaseIterable { case open, sandboxed }`. The raw values are `"open"` and `"sandboxed"`. ACPA-19 sends the value in the `_meta` of the ACP `initialize` result, so the JSON form is a plain string.
- [x] `public struct SandboxProbe: Sendable` with one value `isSandboxed: @Sendable () -> Bool`. `SandboxProbe.live` reads the `com.apple.security.app-sandbox` entitlement of the current process with `SecTaskCreateFromSelf` and `SecTaskCopyValueForEntitlement` (Security framework). When the entitlement cannot be read, it uses the `APP_SANDBOX_CONTAINER_ID` environment variable. Add `SandboxProbe.fixed(_ value: Bool)` so that a test can fake a sandboxed process.
- [x] `public enum ToolModeError: Error, Equatable, Sendable { case openModeInSandbox }` with a clear `LocalizedError` message.
- [x] `extension ToolMode { public func validate(probe: SandboxProbe = .live) throws(ToolModeError) }`. It throws `.openModeInSandbox` when the mode is `.open` and `probe.isSandboxed()` is true. It does not throw in the 3 other cases. Each package calls this one function when it composes its tools, before it registers a tool. So the error comes at composition time, not at the first tool call. Doc comments say this.

Docs (Simplified Technical English):
- [x] `docs/REFERENCE.md`: add a section "Tool modes: `ToolMode`" next to "## Tool hosting: `ToolContext` and `RunPlane`". Tell the two values, the check, the probe, and the rule that a package does not register a tool that cannot work in the App Sandbox in `sandboxed` mode.
- [x] `docs/GUIDE.md`: add a short example that composes tools and calls `try mode.validate()`.

## Acceptance Criteria
- [x] `ToolMode.allCases` is `[.open, .sandboxed]`, and the JSON encoding of `.sandboxed` is the string `"sandboxed"`.
- [x] `ToolMode.open.validate(probe: .fixed(true))` throws `ToolModeError.openModeInSandbox`.
- [x] `ToolMode.open.validate(probe: .fixed(false))`, `ToolMode.sandboxed.validate(probe: .fixed(true))` and `ToolMode.sandboxed.validate(probe: .fixed(false))` do not throw.
- [x] `SandboxProbe.live.isSandboxed()` returns `false` in the `swift test` process (which is not sandboxed).
- [x] No new target or product in `Package.swift`. The build has no new warnings.

## Tests
- [x] Create `Tests/FoundationModelsExtrasTests/Hosting/ToolModeTests.swift` (Swift Testing): Codable round trip of each case, raw values, decoding of an unknown string fails, the 4 cases of `validate(probe:)`, and `SandboxProbe.live` is `false` in the test process.
- [x] Add `ToolMode`, `SandboxProbe` and `ToolModeError` to the public surface check in `Tests/FoundationModelsExtrasTests/Hosting/ToolHostingPublicSurfaceTests.swift`.
- [x] Run `swift test --filter ToolMode` and `swift test --filter ToolHostingPublicSurface`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- When the work is pushed, send the commit to the session testudoapp-75. MT-15, SK-7 and ACPA-19 wait on it. #step1