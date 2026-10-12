import FixtureSupport
import Testing

/// Guards the boundary of the `Marketplace` target: the target knows no skill
/// type, thus no source file under it names a type of `FoundationModelsSkills`,
/// and none imports that module. The target also keeps the layout of its cache
/// to itself, thus no type of that layout stands on the module surface.
///
/// The suite reads the source files as text from the package root, through
/// the shared `FixtureFile.swiftSources(under:)`.
@Suite("Module boundary")
struct ModuleBoundaryTests {
  /// The folder of the marketplace sources, relative to the package root.
  private static let sourcesPath = PackageManifest.marketplaceSourcesPath

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
    let sources = try FixtureFile.swiftSources(under: Self.sourcesPath)

    let offenders = sources.flatMap { source in
      Self.skillsTypeNames.filter { source.text.contains($0) }.map { "\(source.path): \($0)" }
    }

    #expect(!sources.isEmpty, "the check reads at least one source file, or it proves nothing")
    #expect(offenders.isEmpty)
  }

  @Test func noMarketplaceSourceImportsTheSkillsModule() throws {
    let sources = try FixtureFile.swiftSources(under: Self.sourcesPath)

    let offenders = sources.filter { $0.text.contains(Self.skillsModuleImport) }.map(\.path)

    #expect(!sources.isEmpty, "the check reads at least one source file, or it proves nothing")
    #expect(offenders.isEmpty)
  }

  @Test func noCacheLayoutTypeStandsOnTheModuleSurface() throws {
    let sources = try FixtureFile.swiftSources(under: Self.sourcesPath)

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
}
