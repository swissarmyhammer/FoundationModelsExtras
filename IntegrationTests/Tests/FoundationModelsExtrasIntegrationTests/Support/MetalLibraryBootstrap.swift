import Foundation

/// Puts `mlx.metallib` beside the test binary, where MLX looks for its shader
/// library.
///
/// Under `swift test`, SwiftPM puts the shader library in
/// `mlx-swift_Cmlx.bundle` beside the `.xctest` bundle, and the test binary is
/// in `<name>.xctest/Contents/MacOS`. MLX does not find the library there, and
/// the first GPU call stops the process. The FoundationModelsRouter and
/// FoundationModelsMultitool integration suites use the same fix. In CI, the
/// shared workflow copies the library before the run, and then this step does
/// nothing.
enum MetalLibraryBootstrap {
    /// The result of the one link attempt of the process.
    private static let result = Result { try linkIfMissing() }

    /// Makes the link one time for each process. A later call gives the same
    /// result.
    ///
    /// - Throws: The error of the link, when it failed.
    static func install() throws {
        try result.get()
    }

    /// A class, so that `Bundle(for:)` finds the `.xctest` bundle.
    private final class BundleAnchor {}

    /// Links `mlx.metallib` beside the test binary to the library of the Cmlx
    /// bundle. Does nothing when the link is there, or when the build has no
    /// such bundle.
    private static func linkIfMissing() throws {
        let testBundle = Bundle(for: BundleAnchor.self)
        guard let binaryDirectory = testBundle.executableURL?.deletingLastPathComponent() else { return }
        let link = binaryDirectory.appendingPathComponent("mlx.metallib")
        let library = testBundle.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
        let files = FileManager.default
        guard !files.fileExists(atPath: link.path), files.fileExists(atPath: library.path) else { return }
        try files.createSymbolicLink(at: link, withDestinationURL: library)
    }
}
