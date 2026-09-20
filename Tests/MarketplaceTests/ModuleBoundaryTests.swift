import FixtureSupport
import Foundation
import Testing

/// Guards the boundary of the `Marketplace` target (decision 2026-09-19): the
/// target knows no skill type, thus no source file under it names a type of
/// `FoundationModelsSkills`, and none imports that module. The target also
/// keeps the layout of its cache to itself, thus no type of that layout
/// stands on the module surface.
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

  /// The types of the cache layout, which stay inside the target.
  ///
  /// A consumer reads a marketplace list through ``MarketplaceListing``, thus
  /// it never names the state file, the folder name, or the parsed location.
  /// A type of this list on the module surface would make the layout of the
  /// cache a contract that a later change could not alter.
  private static let cacheLayoutTypeNames = [
    "MarketplaceCache", "MarketplaceState", "MarketplaceStateRecord", "MarketplaceIdentity",
    "MarketplaceLocation",
  ]

  /// The access levels that put a declaration on the module surface.
  private static let exportedAccessLevels = ["public", "open"]

  /// The keywords that declare a type, with the modifiers that can stand
  /// between the access level and the keyword.
  private static let typeDeclarations = ["struct", "enum", "class", "final class", "actor"]

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

  @Test func noCacheLayoutTypeStandsOnTheModuleSurface() throws {
    let sources = try Self.sourceTexts()

    let offenders = sources.flatMap { source in
      Self.cacheLayoutTypeNames
        .filter { Self.exportsType(named: $0, in: source.text) }
        .map { "\(source.path): \($0)" }
    }

    #expect(!sources.isEmpty, "the check reads at least one source file, or it proves nothing")
    #expect(offenders.isEmpty)
  }

  // MARK: - Support

  /// Whether one source text declares a type on the module surface.
  ///
  /// - Parameters:
  ///   - name: The type to look for.
  ///   - text: The whole text of one source file.
  /// - Returns: `true` when the text holds a `public` or an `open`
  ///   declaration of that type.
  private static func exportsType(named name: String, in text: String) -> Bool {
    exportedAccessLevels.contains { level in
      typeDeclarations.contains { declaration in
        text.contains("\(level) \(declaration) \(name)")
      }
    }
  }

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
