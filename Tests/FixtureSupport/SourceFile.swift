import Foundation

/// One Swift source file of the package, read as text.
///
/// The source suites of more than one test target read the sources of a
/// target as text and look for a forbidden text in each file.
/// ``FixtureFile/swiftSources(under:)`` gives these files.
public struct SourceFile: Sendable {
  /// The path of the file, relative to the package root, for example
  /// `Sources/Marketplace/MarketplaceStore.swift`.
  public let path: String

  /// The text of the file.
  public let text: String

  /// The name of the file, with its extension.
  public var name: String {
    URL(fileURLWithPath: path).lastPathComponent
  }
}

extension FixtureFile {
  /// The suffix of a Swift source file.
  private static let swiftFileSuffix = ".swift"

  /// Reads each Swift file under one folder of the package, also in each
  /// subfolder.
  ///
  /// - Parameter folder: The folder, relative to the package root.
  /// - Returns: One file for each Swift file, sorted by path.
  /// - Throws: The error of a folder that cannot be listed, or of a file that
  ///   cannot be read.
  public static func swiftSources(under folder: String) throws -> [SourceFile] {
    let root = url(folder)
    let subpaths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
    return try subpaths.filter { $0.hasSuffix(swiftFileSuffix) }.sorted().map { subpath in
      SourceFile(
        path: "\(folder)/\(subpath)",
        text: try String(contentsOf: root.appendingPathComponent(subpath), encoding: .utf8))
    }
  }
}
