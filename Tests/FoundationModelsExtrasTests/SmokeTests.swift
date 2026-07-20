import Testing

@testable import FoundationModelsExtras

/// Scaffolding smoke test for the `FoundationModelsExtras` module.
///
/// The `@testable import FoundationModelsExtras` above is the real assertion:
/// it only compiles and links if the `FoundationModelsExtras` library target
/// builds and exposes an importable module. Reaching and running this `@Test`
/// under `swift test` therefore proves both that the module imports cleanly
/// and that the package's test target executes — no tautological runtime
/// assertion is needed.
///
/// Real behavioral tests for the slash-command, dotfolder-stack, and
/// templating pillars replace this smoke test alongside their implementation
/// in subsequent tasks.
@Suite struct SmokeTests {
  @Test func moduleImportsCleanlyAndTestTargetRuns() {}
}
