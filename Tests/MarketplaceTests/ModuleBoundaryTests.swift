import FixtureSupport
import Foundation
import Testing

/// Guards the boundary of the `Marketplace` target (decision 2026-09-19): the
/// target knows no skill type, thus no source file under it names a type of
/// `FoundationModelsSkills`, and none imports that module.
///
/// The suite reads the source files as text from the package root, as
/// `PackageLayoutTests` reads the manifest.
@Suite("Module boundary")
struct ModuleBoundaryTests {
  /// The folder of the marketplace sources, relative to the package root.
  private static let sourcesPath = "Sources/Marketplace"

  /// The extension of a Swift source file.
  private static let swiftExtension = "swift"

  /// The Skills types that no marketplace source may name.
  private static let skillsTypeNames = ["SkillsRegistry", "SkillDiscovery", "FrontmatterDecoder", "RenderPolicy"]

  /// The import of the Skills module, which no marketplace source may hold.
  private static let skillsModuleImport = "import FoundationModelsSkills"

  @Test func noMarketplaceSourceNamesASkillsType() throws {
    let sources = try Self.sourceTexts()

    let offenders = sources.flatMap { source in
      Self.skillsTypeNames.filter { source.text.contains($0) }.map { "\(source.path): \($0)" }
    }

    #expect(!sources.isEmpty, "the check reads at least one source file, or it proves nothing")
    #expect(offenders.isEmpty)
  }

  @Test func noMarketplaceSourceImportsTheSkillsModule() throws {
    let sources = try Self.sourceTexts()

    let offenders = sources.filter { $0.text.contains(Self.skillsModuleImport) }.map(\.path)

    #expect(!sources.isEmpty, "the check reads at least one source file, or it proves nothing")
    #expect(offenders.isEmpty)
  }

  // MARK: - Support

  /// The text of every Swift source file under ``sourcesPath``, with its
  /// path relative to the package root.
  ///
  /// - Returns: One entry for each file, in enumeration order.
  /// - Throws: The error of a file read, or a failed requirement when the
  ///   folder does not enumerate.
  private static func sourceTexts() throws -> [(path: String, text: String)] {
    let root = FixtureFile.url(sourcesPath)
    let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == swiftExtension }
    return try files.map { file in
      (path: file.path.replacingOccurrences(of: FixtureFile.packageRoot.path, with: ""),
       text: try String(contentsOf: file, encoding: .utf8))
    }
  }
}
