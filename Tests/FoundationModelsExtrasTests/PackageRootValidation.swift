import Foundation

/// Shared package-root lookup for tests that read a checked-in file off disk
/// instead of through `Bundle.module`.
///
/// Kept internal to this single test target rather than split into a separate
/// `TestSupport` module.
enum PackageRootValidation {
  /// The package root directory, derived from the caller's own source-file
  /// path: three levels up from `Tests/FoundationModelsExtrasTests/<file>.swift`.
  ///
  /// The `thisFile` default (`#filePath`) expands at the *call site*, so it
  /// names whichever test file invokes this. Every file in this test target
  /// lives in `Tests/FoundationModelsExtrasTests/`, so the three-levels-up
  /// derivation is identical regardless of caller. `thisFile` is injectable
  /// for tests.
  ///
  /// - Parameter thisFile: The calling source file's path; defaults to the
  ///   call site's `#filePath`.
  /// - Returns: The package root URL.
  static func packageRoot(thisFile: String = #filePath) -> URL {
    URL(fileURLWithPath: thisFile)
      .deletingLastPathComponent()  // <file>.swift -> FoundationModelsExtrasTests/
      .deletingLastPathComponent()  // FoundationModelsExtrasTests/ -> Tests/
      .deletingLastPathComponent()  // Tests/ -> package root
  }
}
