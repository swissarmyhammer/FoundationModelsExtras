import Foundation

/// Shared path-containment guard for tests that resolve a relative path against
/// the package root and must reject paths that escape it via `..` or similar.
///
/// Used by `DocCoverageTests` (scanning `Sources/FoundationModelsExtras`).
/// Mirrors the family's convention (see `FoundationModelsShelltool`'s
/// `TestSupport.PackageRootValidation`), kept internal to this single test
/// target rather than split into a separate `TestSupport` module.
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

    /// Guards against `url` (resolved from a relative path via `..` or similar)
    /// falling outside `root`.
    ///
    /// - Parameters:
    ///   - url: The resolved URL to check.
    ///   - root: The package root URL `url` must equal or be a descendant of.
    ///   - onEscape: Produces the error to throw, given `url`'s standardized
    ///     path, when `url` resolves outside `root`.
    /// - Throws: The error `onEscape` produces if `url`'s standardized path
    ///   isn't `root`'s standardized path or a descendant of it.
    static func requireWithinPackageRoot<E: Error>(
        _ url: URL,
        root: URL,
        throwing onEscape: (String) -> E
    ) throws {
        let standardizedURL = url.standardizedFileURL.path
        let standardizedRoot = root.standardizedFileURL.path
        guard standardizedURL == standardizedRoot || standardizedURL.hasPrefix(standardizedRoot + "/") else {
            throw onEscape(standardizedURL)
        }
    }
}
