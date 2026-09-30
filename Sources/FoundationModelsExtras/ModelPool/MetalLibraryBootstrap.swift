import Foundation

/// Makes the MLX metal library available to the binary that runs
/// ``MLXModelLoader``, one time for each process.
///
/// MLX looks for `mlx.metallib` beside the binary, and then for the
/// `mlx-swift_Cmlx.bundle` of SwiftPM in the main bundle. A SwiftPM
/// executable (`swift run`) has that bundle beside the binary, and MLX finds
/// it with no help. A `.xctest` bundle is different: SwiftPM puts the bundle
/// beside the `.xctest` bundle, and the binary is in
/// `<name>.xctest/Contents/MacOS`. MLX does not find the library there, and
/// the first GPU call stops the process. Thus this step links `mlx.metallib`
/// beside the binary to the library of the bundle. It does nothing when the
/// link is there already, or when no bundle is beside the bundle of the
/// binary, as for an executable.
enum MetalLibraryBootstrap {
    /// The file name of the library that MLX looks for beside the binary.
    private static let libraryName = "mlx.metallib"

    /// The path of the library of SwiftPM, relative to the folder of the
    /// bundle of the binary.
    private static let bundledLibraryPath = "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"

    /// The result of the one link attempt of the process.
    private static let result = Result { try linkBesideTheBinaryOfThisModule() }

    /// Makes the link one time for each process. A later call gives the same
    /// result.
    ///
    /// - Throws: The error of the link, when it failed.
    static func install() throws {
        try result.get()
    }

    /// A class of this module, so that `Bundle(for:)` finds the bundle that
    /// holds the binary of the module: the `.xctest` bundle in a test run, or
    /// the main bundle of an executable.
    private final class BundleAnchor {}

    /// Links `mlx.metallib` beside the binary of the bundle of this module.
    ///
    /// - Throws: The error of the link.
    private static func linkBesideTheBinaryOfThisModule() throws {
        let bundle = Bundle(for: BundleAnchor.self)
        guard let binary = bundle.executableURL else { return }
        try linkIfMissing(
            binaryDirectory: binary.deletingLastPathComponent(),
            bundleParentDirectory: bundle.bundleURL.deletingLastPathComponent())
    }

    /// Links `mlx.metallib` in `binaryDirectory` to the library of the Cmlx
    /// bundle in `bundleParentDirectory`. Does nothing when the link is there,
    /// or when no such bundle is there.
    ///
    /// - Parameters:
    ///   - binaryDirectory: The folder of the binary.
    ///   - bundleParentDirectory: The folder that holds the bundle of the
    ///     binary, where SwiftPM puts the Cmlx bundle.
    /// - Throws: The error of the link.
    static func linkIfMissing(binaryDirectory: URL, bundleParentDirectory: URL) throws {
        let link = binaryDirectory.appendingPathComponent(libraryName)
        let library = bundleParentDirectory.appendingPathComponent(bundledLibraryPath)
        let files = FileManager.default
        guard !files.fileExists(atPath: link.path), files.fileExists(atPath: library.path) else { return }
        try files.createSymbolicLink(at: link, withDestinationURL: library)
    }
}
