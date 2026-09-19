import Foundation
import FoundationModelsExtras

/// The skills of one marketplace after ``CatalogResolver`` applies the
/// catalog and the host selection (marketplace.md §5.2 and §6.4).
internal struct ResolvedCatalog: Sendable, Hashable {
  /// The catalog `name`, or `nil` when the resolver scanned the repository.
  var name: String?

  /// The catalog `metadata.version`, or `nil` when there is none.
  var version: String?

  /// The selected skills, in catalog order.
  var skills: [ResolvedSkill]

  /// The `renames` map of the catalog. It is empty for a scan.
  var renames: [String: String?]

  /// The findings of the resolution. Each problem is one diagnostic.
  var diagnostics: [MarketplaceDiagnostic]
}

/// One skill that a marketplace gives.
internal struct ResolvedSkill: Sendable, Hashable {
  /// The skill name: the name of the skill folder, or the frontmatter
  /// `name` of the root document that marks an entry folder.
  var name: String

  /// The path of the skill folder in the tree. The empty path is the root.
  var path: String

  /// The plugin that lists the skill, or `nil` for a scan.
  var plugin: String?
}

/// Reads the catalog of a marketplace from a ``CatalogFileSource`` and
/// resolves the list of skills (marketplace.md §5.2 and §6.4).
///
/// The resolver looks for these, in order, and uses the first that it finds:
///
/// 1. `.claude-plugin/marketplace.json`.
/// 2. `.agents/plugins/marketplace.json` (Codex). The same rules apply.
/// 3. No catalog: a scan of the repository for the document that marks an
///    entry folder, to a depth of ``maximumScanDepth``. The shallower
///    document wins.
///
/// The skills of a plugin are its `skills` array, else the folders of
/// `<plugin source>/skills/` that hold the document that marks an entry
/// folder. A plugin with a remote source is skipped. When two plugins give
/// the same skill name, the later plugin wins. A selected name that the
/// catalog renamed maps to the new name, and a name that the catalog removed
/// selects nothing.
///
/// The ``MarketplaceLayout`` of the host names the document, thus the
/// resolver holds no knowledge of what an entry is.
///
/// The resolver never throws. Each problem gives one ``MarketplaceDiagnostic``,
/// and the resolver continues where it can.
internal enum CatalogResolver {
  /// The catalog paths, in the order that the resolver reads them.
  static let catalogPaths = [".claude-plugin/marketplace.json", ".agents/plugins/marketplace.json"]

  /// The deepest document that a scan finds, as a count of path
  /// components: a document in the root is 1, and `skills/<name>/<document>`
  /// is 3.
  static let maximumScanDepth = 3

  /// The depth of a document in the root folder, as a count of path
  /// components. The scan starts here.
  static let rootDepth = 1

  /// The folder of a plugin that holds its skill folders when the plugin
  /// has no `skills` array.
  static let pluginSkillsFolderName = "skills"

  /// The result of the read of one catalog path.
  private enum CatalogRead {
    /// The file is a catalog.
    case found(MarketplaceCatalog)

    /// No file is at the path.
    case missing

    /// The file is at the path, but it cannot be read or decoded.
    case unusable(MarketplaceDiagnostic)
  }

  /// Resolves the skills of one marketplace tree.
  ///
  /// - Parameters:
  ///   - source: The files of the tree.
  ///   - selection: The skills that the host takes from the marketplace.
  ///   - layout: The document that marks an entry folder, and the folder
  ///     names that a scan skips.
  /// - Returns: The selected skills, with a diagnostic for each problem.
  static func resolve(
    from source: any CatalogFileSource, selection: SkillSelection, layout: MarketplaceLayout
  ) -> ResolvedCatalog {
    for path in catalogPaths {
      switch readCatalog(atPath: path, from: source) {
      case .missing:
        continue
      case .unusable(let diagnostic):
        return ResolvedCatalog(name: nil, version: nil, skills: [], renames: [:], diagnostics: [diagnostic])
      case .found(let catalog):
        return CatalogReader(source: source, layout: layout, marketplaceID: catalog.name).resolved(
          catalog: catalog, selection: selection)
      }
    }
    return CatalogReader(source: source, layout: layout, marketplaceID: nil).scanned(selection: selection)
  }

  /// Reads and decodes the catalog at one path.
  ///
  /// - Parameters:
  ///   - path: The catalog path in the tree.
  ///   - source: The files of the tree.
  /// - Returns: The catalog, the fact that no file is at the path, or an
  ///   error diagnostic.
  private static func readCatalog(atPath path: String, from source: any CatalogFileSource) -> CatalogRead {
    do {
      guard let data = try source.contents(atPath: path) else {
        return .missing
      }
      return try .found(JSONDecoder().decode(MarketplaceCatalog.self, from: data))
    } catch {
      return .unusable(
        MarketplaceDiagnostic(
          severity: .error, marketplaceID: nil, message: #"The catalog "\#(path)" is not usable: \#(error)"#))
    }
  }
}

/// A value, with the diagnostics of the step that made it.
///
/// ``CatalogReader`` and the `Array` extension read it, thus it is
/// `fileprivate` and not `private`.
fileprivate struct Diagnosed<Value> {
  /// The value of the step.
  var value: Value

  /// The findings of the step.
  var diagnostics: [MarketplaceDiagnostic] = []

  /// Changes the value and keeps the diagnostics.
  ///
  /// - Parameter transform: The change of the value.
  /// - Returns: The changed value, with the same diagnostics.
  func map<NewValue>(using transform: (Value) -> NewValue) -> Diagnosed<NewValue> {
    Diagnosed<NewValue>(value: transform(value), diagnostics: diagnostics)
  }
}

extension Array {
  /// Joins the results of a step that can give no value for an item.
  ///
  /// - Returns: The values that are present, in order, with the diagnostics
  ///   of every result, in order.
  fileprivate func collected<Item>() -> Diagnosed<[Item]> where Element == Diagnosed<Item?> {
    Diagnosed(value: compactMap(\.value), diagnostics: flatMap(\.diagnostics))
  }
}

/// The steps of one resolution over one tree.
///
/// ``CatalogResolver`` reads it, thus it is `fileprivate` and not `private`.
fileprivate struct CatalogReader {
  /// What a selected name names, for the text of a diagnostic.
  enum SelectionNoun: String {
    /// A plugin name.
    case plugin

    /// A skill name.
    case skill

    /// Gives the names that a selection of this kind names.
    ///
    /// - Parameter selection: The host selection.
    /// - Returns: The names, or `nil` when the selection is of a
    ///   different kind.
    func selectedNames(in selection: SkillSelection) -> [String]? {
      switch (self, selection) {
      case (.plugin, .plugins(let names)), (.skill, .skills(let names)):
        names
      case (.plugin, _), (.skill, _):
        nil
      }
    }
  }

  /// Which skill wins when two skills have the same name.
  enum DuplicateWinner {
    /// The first skill wins: the shallower document of a scan.
    case first

    /// The last skill wins: the later plugin of a catalog.
    case last
  }

  /// The key of the frontmatter that names the root entry.
  private static let nameKey = "name"

  /// The files of the tree.
  let source: any CatalogFileSource

  /// The document that marks an entry folder, and the folder names that a
  /// scan skips.
  let layout: MarketplaceLayout

  /// The marketplace id that each diagnostic carries: the catalog name, or
  /// `nil` for a scan.
  let marketplaceID: String?

  // MARK: - Catalog

  /// Resolves the skills of a catalog.
  ///
  /// - Parameters:
  ///   - catalog: The decoded catalog.
  ///   - selection: The host selection.
  /// - Returns: The selected skills, with a diagnostic for each problem.
  func resolved(catalog: MarketplaceCatalog, selection: SkillSelection) -> ResolvedCatalog {
    let renamed = renamedSelection(of: selection, renames: catalog.renames)
    let plugins = selectedItems(items: catalog.plugins, by: renamed.value, noun: .plugin, nameOf: \.name)
    let listed = plugins.value.map { skills(of: $0) }
    let unique = deduplicated(skills: listed.flatMap(\.value), winner: .last)
    let selected = selectedItems(items: unique.value, by: renamed.value, noun: .skill, nameOf: \.name)
    return ResolvedCatalog(
      name: catalog.name, version: catalog.metadata?.version, skills: selected.value, renames: catalog.renames,
      diagnostics: renamed.diagnostics + plugins.diagnostics + listed.flatMap(\.diagnostics)
        + unique.diagnostics + selected.diagnostics)
  }

  /// Finds the skills of one plugin.
  ///
  /// - Parameter plugin: The plugin entry.
  /// - Returns: The skills of the plugin. A remote plugin gives no skill and
  ///   one warning.
  func skills(of plugin: MarketplaceCatalog.Plugin) -> Diagnosed<[ResolvedSkill]> {
    switch plugin.source {
    case .remote(let remote):
      Diagnosed(value: [], diagnostics: [remoteSourceDiagnostic(plugin: plugin.name, source: remote)])
    case .relative(let path):
      skills(of: plugin, inFolder: path)
    }
  }

  /// Finds the skills of one plugin with a relative source.
  ///
  /// - Parameters:
  ///   - plugin: The plugin entry.
  ///   - path: The source path of the plugin, as the catalog writes it.
  /// - Returns: The skills of the `skills` array, else of the
  ///   `<source>/skills/` folder.
  func skills(of plugin: MarketplaceCatalog.Plugin, inFolder path: String) -> Diagnosed<[ResolvedSkill]> {
    guard let root = CatalogPath.normalized(path: path) else {
      let message =
        #"The plugin "\#(plugin.name)" has the source path "\#(path)", which is not a relative path in the repository. The resolver skips this plugin."#
      return Diagnosed(value: [], diagnostics: [diagnostic(severity: .warning, saying: message)])
    }
    guard let entries = plugin.skills else {
      return folderSkills(ofPlugin: plugin.name, root: root)
    }
    return entries.map { listedSkill(entry: $0, ofPlugin: plugin.name, root: root) }.collected()
  }

  /// Finds one skill of a `skills` array.
  ///
  /// - Parameters:
  ///   - entry: The entry of the array, relative to the plugin source.
  ///   - plugin: The name of the plugin.
  ///   - root: The normalized source path of the plugin.
  /// - Returns: The skill, or `nil` and one diagnostic when the entry is not
  ///   a skill folder.
  func listedSkill(entry: String, ofPlugin plugin: String, root: String) -> Diagnosed<ResolvedSkill?> {
    guard let path = CatalogPath.resolved(relativePath: entry, inFolder: root),
      let name = CatalogPath.lastComponent(of: path)
    else {
      let message =
        #"The plugin "\#(plugin)" lists the skill path "\#(entry)", which is not a folder in the repository. The resolver skips it."#
      return Diagnosed(value: nil, diagnostics: [diagnostic(severity: .warning, saying: message)])
    }
    do {
      guard try hasDocument(inFolder: path) else {
        let message =
          #"The plugin "\#(plugin)" lists the skill folder "\#(path)", which has no \#(layout.documentName) file. The resolver skips it."#
        return Diagnosed(value: nil, diagnostics: [diagnostic(severity: .warning, saying: message)])
      }
      return Diagnosed(value: ResolvedSkill(name: name, path: path, plugin: plugin))
    } catch {
      return Diagnosed(value: nil, diagnostics: [readFailure(atPath: path, error: error)])
    }
  }

  /// Finds the skills of a plugin that has no `skills` array: the folders
  /// of `<root>/skills/` that hold the document that marks an entry folder.
  ///
  /// A folder with no such document is not a skill, and it gives no
  /// diagnostic.
  ///
  /// - Parameters:
  ///   - plugin: The name of the plugin.
  ///   - root: The normalized source path of the plugin.
  /// - Returns: The skills, in name order. A plugin with no skills folder
  ///   gives no skill.
  func folderSkills(ofPlugin plugin: String, root: String) -> Diagnosed<[ResolvedSkill]> {
    let folder = CatalogPath.child(named: CatalogResolver.pluginSkillsFolderName, of: root)
    do {
      let skills = try source.entries(inDirectory: folder)
        .filter { isSubfolder(entry: $0) }
        .map { ResolvedSkill(name: $0.name, path: CatalogPath.child(named: $0.name, of: folder), plugin: plugin) }
        .filter { try hasDocument(inFolder: $0.path) }
      return Diagnosed(value: skills)
    } catch {
      return Diagnosed(value: [], diagnostics: [readFailure(atPath: folder, error: error)])
    }
  }

  // MARK: - Scan

  /// Resolves the skills of a tree that has no catalog.
  ///
  /// - Parameter selection: The host selection.
  /// - Returns: The selected skills of the scan. A scan has no plugin, so a
  ///   ``SkillSelection/plugins(_:)`` selection gives no skill and one
  ///   warning for each name.
  func scanned(selection: SkillSelection) -> ResolvedCatalog {
    guard case .plugins = selection else {
      let found = scannedSkills()
      let selected = selectedItems(items: found.value, by: selection, noun: .skill, nameOf: \.name)
      return ResolvedCatalog(
        name: nil, version: nil, skills: selected.value, renames: [:],
        diagnostics: found.diagnostics + selected.diagnostics)
    }
    let noPlugins: [MarketplaceCatalog.Plugin] = []
    let unknownPlugins = selectedItems(items: noPlugins, by: selection, noun: .plugin, nameOf: \.name)
    return ResolvedCatalog(
      name: nil, version: nil, skills: [], renames: [:], diagnostics: unknownPlugins.diagnostics)
  }

  /// Scans the tree for skills, to a depth of
  /// ``CatalogResolver/maximumScanDepth``.
  ///
  /// - Returns: One skill for each name. The shallower document wins, and
  ///   each deeper skill with the same name gives one warning.
  func scannedSkills() -> Diagnosed<[ResolvedSkill]> {
    let folders = skillFolders(in: [""], depth: CatalogResolver.rootDepth)
    let named = folders.value.map { scannedSkill(atFolder: $0) }.collected()
    let unique = deduplicated(skills: named.value, winner: .first)
    return Diagnosed(
      value: unique.value, diagnostics: folders.diagnostics + named.diagnostics + unique.diagnostics)
  }

  /// Finds the folders that hold the document that marks an entry folder,
  /// one level at a time.
  ///
  /// - Parameters:
  ///   - folders: The folders of one level, in walk order.
  ///   - depth: The depth of a document in these folders.
  /// - Returns: The skill folders of this level and of the deeper levels,
  ///   shallower first.
  func skillFolders(in folders: [String], depth: Int) -> Diagnosed<[String]> {
    guard depth <= CatalogResolver.maximumScanDepth, !folders.isEmpty else {
      return Diagnosed(value: [])
    }
    let listings = folders.map { (folder: $0, listing: listing(ofFolder: $0)) }
    let found = listings.filter { $0.listing.value.contains { isDocument(entry: $0) } }.map(\.folder)
    let children = listings.flatMap { level in
      level.listing.value.filter { isSubfolder(entry: $0) }.map { CatalogPath.child(named: $0.name, of: level.folder) }
    }
    let deeper = skillFolders(in: children, depth: depth + 1)
    return Diagnosed(
      value: found + deeper.value, diagnostics: listings.flatMap(\.listing.diagnostics) + deeper.diagnostics)
  }

  /// Names the skill of one scanned folder.
  ///
  /// - Parameter folder: The skill folder. The empty path is the root.
  /// - Returns: The skill. A folder skill takes the folder name. The root
  ///   skill takes the frontmatter `name` of its document.
  func scannedSkill(atFolder folder: String) -> Diagnosed<ResolvedSkill?> {
    guard folder.isEmpty else {
      return Diagnosed(
        value: CatalogPath.lastComponent(of: folder).map { ResolvedSkill(name: $0, path: folder, plugin: nil) })
    }
    do {
      guard let name = try rootEntryName() else {
        let message =
          "The root \(layout.documentName) has no frontmatter name that is one folder name. The resolver skips it."
        return Diagnosed(value: nil, diagnostics: [diagnostic(severity: .warning, saying: message)])
      }
      return Diagnosed(value: ResolvedSkill(name: name, path: "", plugin: nil))
    } catch {
      return Diagnosed(value: nil, diagnostics: [readFailure(atPath: layout.documentName, error: error)])
    }
  }

  /// Reads the frontmatter `name` of the root document that marks an entry
  /// folder.
  ///
  /// The frontmatter is the text between the `---` fences, parsed as YAML.
  /// A document with no frontmatter, a frontmatter that does not parse, and
  /// a `name` that is not a text value each give no name.
  ///
  /// - Returns: The name, or `nil` when the file has no name that is one
  ///   folder name.
  /// - Throws: The error of the file read.
  func rootEntryName() throws -> String? {
    guard let data = try source.contents(atPath: layout.documentName) else {
      return nil
    }
    let text = String(decoding: data, as: UTF8.self)
    guard let frontmatter = FrontmatterDocument.split(text: text).frontmatter,
      case .dictionary(let fields)? = try? YAMLValue.parse(frontmatter),
      case .string(let name)? = fields[Self.nameKey], CatalogPath.isSingleComponent(name: name)
    else {
      return nil
    }
    return name
  }

  // MARK: - Selection

  /// Applies the `renames` map of the catalog to the names of a selection.
  ///
  /// - Parameters:
  ///   - selection: The host selection.
  ///   - renames: The `renames` map of the catalog.
  /// - Returns: The selection with the new names. Each renamed name gives
  ///   one advisory, and each removed name gives one warning.
  func renamedSelection(of selection: SkillSelection, renames: [String: String?]) -> Diagnosed<SkillSelection> {
    switch selection {
    case .all:
      Diagnosed(value: .all)
    case .plugins(let names):
      renamedNames(of: names, renames: renames).map(using: SkillSelection.plugins)
    case .skills(let names):
      renamedNames(of: names, renames: renames).map(using: SkillSelection.skills)
    }
  }

  /// Applies the `renames` map of the catalog to a list of selected names.
  ///
  /// - Parameters:
  ///   - names: The selected names.
  ///   - renames: The `renames` map of the catalog.
  /// - Returns: The names after the map, with no removed name.
  func renamedNames(of names: [String], renames: [String: String?]) -> Diagnosed<[String]> {
    names.map { renamedName(of: $0, renames: renames) }.collected()
  }

  /// Applies the `renames` map of the catalog to one selected name.
  ///
  /// - Parameters:
  ///   - name: The selected name.
  ///   - renames: The `renames` map of the catalog.
  /// - Returns: The same name when the map does not have it, the new name
  ///   with one advisory, or `nil` with one warning when the catalog
  ///   removed the name.
  func renamedName(of name: String, renames: [String: String?]) -> Diagnosed<String?> {
    guard let entry = renames[name] else {
      return Diagnosed(value: name)
    }
    guard let newName = entry else {
      let message = #"The selected name "\#(name)" is removed from the catalog. It selects nothing."#
      return Diagnosed(value: nil, diagnostics: [diagnostic(severity: .warning, saying: message)])
    }
    let message = #"The selected name "\#(name)" is renamed to "\#(newName)" in the catalog. The resolver uses "\#(newName)"."#
    return Diagnosed(value: newName, diagnostics: [diagnostic(severity: .advisory, saying: message)])
  }

  /// Keeps the items that a selection names, when the selection names this
  /// kind of item.
  ///
  /// - Parameters:
  ///   - items: The items, in catalog order.
  ///   - selection: The selection, after the renames.
  ///   - noun: The kind of the items. Only a selection of this kind removes
  ///     items.
  ///   - nameOf: The name of an item.
  /// - Returns: The selected items in catalog order. A selection of a
  ///   different kind keeps every item.
  func selectedItems<Item>(
    items: [Item], by selection: SkillSelection, noun: SelectionNoun, nameOf: (Item) -> String
  ) -> Diagnosed<[Item]> {
    guard let names = noun.selectedNames(in: selection) else {
      return Diagnosed(value: items)
    }
    return filtered(items: items, keepingNames: names, noun: noun, nameOf: nameOf)
  }

  /// Keeps the items that a list of names names.
  ///
  /// - Parameters:
  ///   - items: The items, in order.
  ///   - names: The selected names.
  ///   - noun: What a name names, for the text of a diagnostic.
  ///   - nameOf: The name of an item.
  /// - Returns: The named items, in order. Each name that no item has gives
  ///   one warning.
  func filtered<Item>(
    items: [Item], keepingNames names: [String], noun: SelectionNoun, nameOf: (Item) -> String
  ) -> Diagnosed<[Item]> {
    let wanted = Set(names)
    let known = Set(items.map(nameOf))
    return Diagnosed(
      value: items.filter { wanted.contains(nameOf($0)) },
      diagnostics: names.filter { !known.contains($0) }.map { name in
        diagnostic(
          severity: .warning, saying: #"The selected \#(noun.rawValue) "\#(name)" is not in the marketplace."#)
      })
  }

  // MARK: - Shared steps

  /// Keeps one skill for each name.
  ///
  /// - Parameters:
  ///   - skills: The skills, in order.
  ///   - winner: Which skill wins when two skills have the same name.
  /// - Returns: The winning skills, in order. Each losing skill gives one
  ///   warning.
  func deduplicated(skills: [ResolvedSkill], winner: DuplicateWinner) -> Diagnosed<[ResolvedSkill]> {
    let winners = Dictionary(skills.indices.map { (skills[$0].name, $0) }) { first, later in
      winner == .first ? first : later
    }
    return Diagnosed(
      value: skills.indices.filter { winners[skills[$0].name] == $0 }.map { skills[$0] },
      diagnostics: skills.indices.compactMap { index in
        guard let kept = winners[skills[index].name], kept != index else {
          return nil
        }
        return duplicateDiagnostic(loser: skills[index], winner: skills[kept])
      })
  }

  /// Lists one folder of the tree.
  ///
  /// - Parameter folder: The folder path.
  /// - Returns: The items, or no item and one error when the list fails.
  func listing(ofFolder folder: String) -> Diagnosed<[CatalogTreeEntry]> {
    do {
      return try Diagnosed(value: source.entries(inDirectory: folder))
    } catch {
      return Diagnosed(value: [], diagnostics: [readFailure(atPath: folder, error: error)])
    }
  }

  /// Tells whether a folder holds the document that marks an entry folder.
  ///
  /// - Parameter path: The folder path.
  /// - Returns: `true` when the folder has a regular file with the name
  ///   ``MarketplaceLayout/documentName``.
  /// - Throws: The error of the folder list.
  func hasDocument(inFolder path: String) throws -> Bool {
    try source.entries(inDirectory: path).contains { isDocument(entry: $0) }
  }

  /// Tells whether an item is the document that marks its folder as an
  /// entry.
  ///
  /// - Parameter entry: The item.
  /// - Returns: `true` for a regular file with the name
  ///   ``MarketplaceLayout/documentName``. A symbolic link with that name is
  ///   not a document.
  func isDocument(entry: CatalogTreeEntry) -> Bool {
    guard entry.name == layout.documentName, case .file = entry.kind else {
      return false
    }
    return true
  }

  /// Tells whether the resolver reads into an item as a folder.
  ///
  /// - Parameter entry: The item.
  /// - Returns: `true` for a real folder whose name the layout does not
  ///   exclude. A symbolic link and a submodule are never read.
  func isSubfolder(entry: CatalogTreeEntry) -> Bool {
    guard !layout.excludedDirectoryNames.contains(entry.name) else {
      return false
    }
    switch entry.kind {
    case .directory:
      return true
    case .file, .symlink, .submodule:
      return false
    }
  }

  // MARK: - Diagnostics

  /// Makes a diagnostic about this marketplace.
  ///
  /// - Parameters:
  ///   - severity: How serious the diagnostic is.
  ///   - message: The text of the diagnostic.
  /// - Returns: The diagnostic, with ``marketplaceID``.
  func diagnostic(severity: MarketplaceDiagnostic.Severity, saying message: String) -> MarketplaceDiagnostic {
    MarketplaceDiagnostic(severity: severity, marketplaceID: marketplaceID, message: message)
  }

  /// Makes the error for a path that the source cannot read.
  ///
  /// - Parameters:
  ///   - path: The path in the tree.
  ///   - error: The error of the source.
  /// - Returns: An error diagnostic.
  func readFailure(atPath path: String, error: any Error) -> MarketplaceDiagnostic {
    diagnostic(severity: .error, saying: #"The resolver cannot read "\#(CatalogPath.display(path: path))": \#(error)"#)
  }

  /// Makes the warning for a plugin with a remote source.
  ///
  /// - Parameters:
  ///   - plugin: The name of the plugin.
  ///   - remote: The source object of the plugin.
  /// - Returns: A warning that names the plugin and its source.
  func remoteSourceDiagnostic(plugin: String, source remote: MarketplaceCatalog.RemotePluginSource) -> MarketplaceDiagnostic {
    let location = (remote.url ?? remote.repo).map { " \($0)" } ?? ""
    let message =
      #"The plugin "\#(plugin)" has a remote source (\#(remote.kind)\#(location)). The resolver reads only relative plugin sources, so it skips this plugin."#
    return diagnostic(severity: .warning, saying: message)
  }

  /// Makes the warning for a skill that loses to a skill with the same
  /// name.
  ///
  /// - Parameters:
  ///   - loser: The skill that the resolver does not use.
  ///   - winner: The skill that the resolver uses.
  /// - Returns: A warning that names the two skill folders.
  func duplicateDiagnostic(loser: ResolvedSkill, winner: ResolvedSkill) -> MarketplaceDiagnostic {
    let message =
      #"Two skills have the name "\#(winner.name)": \#(Self.described(skill: loser)) and \#(Self.described(skill: winner)). The resolver uses "\#(CatalogPath.display(path: winner.path))"."#
    return diagnostic(severity: .warning, saying: message)
  }

  /// Describes a skill for the text of a diagnostic.
  ///
  /// - Parameter skill: The skill.
  /// - Returns: The quoted folder path, and the plugin when there is one.
  static func described(skill: ResolvedSkill) -> String {
    let folder = #""\#(CatalogPath.display(path: skill.path))""#
    return skill.plugin.map { #"\#(folder) (plugin "\#($0)")"# } ?? folder
  }
}
