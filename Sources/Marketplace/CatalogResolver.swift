import Foundation
import FoundationModelsExtras

/// The skills and the agents of one marketplace after the scan of
/// ``CatalogResolver`` and the host selection.
internal struct ResolvedCatalog: Sendable, Hashable {
  /// The selected skills, in scan order.
  var skills: [ResolvedEntry]

  /// The agents, in scan order. Only ``SkillSelection/all`` takes the
  /// agents.
  var agents: [ResolvedEntry] = []

  /// The findings of the scan. Each problem is one diagnostic.
  var diagnostics: [MarketplaceDiagnostic]
}

/// One entry folder that a marketplace gives: a skill or an agent.
///
/// The resolver knows an entry by its folder. It reads no text of the
/// folder, except the frontmatter `name` of a document at the root of the
/// tree.
internal struct ResolvedEntry: Sendable, Hashable {
  /// The entry name: the name of the entry folder, or the frontmatter
  /// `name` of the document at the root of the tree.
  var name: String

  /// The path of the entry folder in the tree. The empty path is the root.
  var path: String
}

/// Finds the skills and the agents of a marketplace tree by a folder scan.
///
/// A marketplace is only a folder. The resolver reads no catalog file. It
/// walks the tree from the root, one level at a time, with no depth limit:
///
/// - A folder that holds a regular file with the name
///   ``MarketplaceLayout/documentName`` is a skill. The folder name is the
///   skill name.
/// - A folder that holds a regular file with the name
///   ``MarketplaceLayer/agentDocumentName`` is an agent. The folder name is
///   the agent name.
/// - The resolver does not read into an entry folder: its files are its
///   resources.
/// - A folder that holds both documents gives one warning, and it is no
///   entry.
/// - The resolver does not read into a folder whose name the layout
///   excludes, into a symbolic link, or into a submodule.
/// - A document at the root of the tree makes the whole tree one entry. Its
///   frontmatter `name` is the entry name.
///
/// When two entries of the same kind have the same name, the shallower
/// entry wins. At the same depth, the first entry in path order wins. Each
/// entry that loses gives one warning. A skill with the name
/// ``MarketplaceLayer/agentsDirectoryName`` gets one warning, and the
/// resolver skips it, because that name is reserved at the layer root.
///
/// An `.md` file directly in a folder with the name
/// ``MarketplaceLayer/agentsDirectoryName`` is an agent file of the old
/// layout. It gives one warning that tells where to move it, and it is no
/// agent.
///
/// The selection ``SkillSelection/all`` takes every skill and every agent.
/// ``SkillSelection/skills(_:)`` takes the named skills and no agent.
///
/// The ``MarketplaceLayout`` of the host names the skill document, thus the
/// resolver holds no knowledge of what a skill is.
///
/// The resolver never throws. Each problem gives one ``MarketplaceDiagnostic``,
/// and the resolver continues where it can.
internal enum CatalogResolver {
  /// Resolves the skills and the agents of one marketplace tree.
  ///
  /// - Parameters:
  ///   - source: The files of the tree.
  ///   - selection: The skills that the host takes from the marketplace.
  ///   - layout: The document that marks a skill folder, and the folder
  ///     names that the scan skips.
  /// - Returns: The selected entries, with a diagnostic for each problem.
  static func resolve(
    from source: any CatalogFileSource, selection: SkillSelection, layout: MarketplaceLayout
  ) -> ResolvedCatalog {
    TreeScanner(source: source, layout: layout).resolved(selection: selection)
  }
}

/// A value, with the diagnostics of the step that made it.
///
/// ``TreeScanner`` reads it, thus it is `fileprivate` and not `private`.
fileprivate struct Diagnosed<Value> {
  /// The value of the step.
  var value: Value

  /// The findings of the step.
  var diagnostics: [MarketplaceDiagnostic] = []
}

/// The two kinds of entry folder.
///
/// ``TreeScanner`` reads it, thus it is `fileprivate` and not `private`.
fileprivate enum EntryKind: CaseIterable {
  /// A folder that holds the document of the layout.
  case skill

  /// A folder that holds ``MarketplaceLayer/agentDocumentName``.
  case agent

  /// The kind in the plural, for the text of a diagnostic.
  var pluralNoun: String {
    switch self {
    case .skill: "skills"
    case .agent: "agents"
    }
  }

  /// The name of the document that marks a folder of this kind.
  ///
  /// - Parameter layout: The layout of the host.
  /// - Returns: The document name.
  func documentName(in layout: MarketplaceLayout) -> String {
    switch self {
    case .skill: layout.documentName
    case .agent: MarketplaceLayer.agentDocumentName
    }
  }
}

/// What the walk of a tree found, before the selection.
///
/// ``TreeScanner`` reads it, thus it is `fileprivate` and not `private`.
fileprivate struct ScanResult {
  /// The skill folders, in scan order: shallower first, then path order.
  var skills: [ResolvedEntry] = []

  /// The agent folders, in scan order.
  var agents: [ResolvedEntry] = []

  /// The findings about the tree: a read failure, a folder with two
  /// documents, and a root document with no name.
  var diagnostics: [MarketplaceDiagnostic] = []

  /// The findings about the agent files of the old layout. Only a selection
  /// that takes the agents reports them.
  var oldAgentFileDiagnostics: [MarketplaceDiagnostic] = []

  /// Adds one entry of one kind.
  ///
  /// - Parameters:
  ///   - entry: The entry folder.
  ///   - kind: Whether the folder is a skill or an agent.
  mutating func append(_ entry: ResolvedEntry, as kind: EntryKind) {
    switch kind {
    case .skill: skills.append(entry)
    case .agent: agents.append(entry)
    }
  }
}

/// The steps of one scan over one tree.
///
/// ``CatalogResolver`` reads it, thus it is `fileprivate` and not `private`.
fileprivate struct TreeScanner {
  /// The key of the frontmatter that names the root entry.
  private static let nameKey = "name"

  /// The extension of an agent file of the old layout.
  private static let oldAgentFileExtension = ".md"

  /// The path of the root of the tree, where the walk starts.
  private static let treeRoot = ""

  /// The files of the tree.
  let source: any CatalogFileSource

  /// The document that marks a skill folder, and the folder names that the
  /// scan skips.
  let layout: MarketplaceLayout

  // MARK: - The resolution

  /// Scans the tree and applies the host selection.
  ///
  /// - Parameter selection: The host selection.
  /// - Returns: The selected skills, the agents when the selection takes
  ///   them, and the findings.
  func resolved(selection: SkillSelection) -> ResolvedCatalog {
    let found = scan()
    let skills = deduplicated(found.skills, kind: .skill)
    let selected = selectedSkills(skills.value, by: selection)
    let kept = unreserved(skills: selected.value)
    let takesAgents = Self.takesAgents(selection)
    let agents = takesAgents ? deduplicated(found.agents, kind: .agent) : Diagnosed(value: [])
    let agentFindings = takesAgents ? found.oldAgentFileDiagnostics : []
    return ResolvedCatalog(
      skills: kept.value, agents: agents.value,
      diagnostics: found.diagnostics + skills.diagnostics + selected.diagnostics + kept.diagnostics
        + agentFindings + agents.diagnostics)
  }

  /// Tells whether a selection takes the agents.
  ///
  /// - Parameter selection: The host selection.
  /// - Returns: `true` for ``SkillSelection/all``. A
  ///   ``SkillSelection/skills(_:)`` selection names skills only, thus it
  ///   takes no agent.
  static func takesAgents(_ selection: SkillSelection) -> Bool {
    switch selection {
    case .all: true
    case .skills: false
    }
  }

  // MARK: - The walk

  /// Walks the tree from the root, one level at a time, with no depth
  /// limit.
  ///
  /// - Returns: The entry folders in scan order, with the findings.
  func scan() -> ScanResult {
    var result = ScanResult()
    var level = [Self.treeRoot]
    while !level.isEmpty {
      level = level.flatMap { visit(folder: $0, into: &result) }
    }
    return result
  }

  /// Reads one folder of the walk.
  ///
  /// - Parameters:
  ///   - folder: The folder path. The empty path is the root.
  ///   - result: What the walk found so far.
  /// - Returns: The subfolders that the walk reads next. An entry folder,
  ///   and a folder with two documents, give none.
  func visit(folder: String, into result: inout ScanResult) -> [String] {
    let listing = listing(ofFolder: folder)
    result.diagnostics += listing.diagnostics
    let kinds = EntryKind.allCases.filter { kind in listing.value.contains { isDocument($0, of: kind) } }
    guard let kind = kinds.first else {
      result.oldAgentFileDiagnostics += oldAgentFileDiagnostics(inFolder: folder, entries: listing.value)
      return listing.value.filter(isSubfolder).map { CatalogPath.child(named: $0.name, of: folder) }
    }
    guard kinds.count == 1 else {
      result.diagnostics.append(twoDocumentsDiagnostic(folder: folder))
      return []
    }
    let named = entry(atFolder: folder, kind: kind)
    result.diagnostics += named.diagnostics
    if let entry = named.value {
      result.append(entry, as: kind)
    }
    return []
  }

  /// Names the entry of one folder that holds the document of its kind.
  ///
  /// - Parameters:
  ///   - folder: The entry folder. The empty path is the root.
  ///   - kind: Whether the folder is a skill or an agent.
  /// - Returns: The entry. A folder entry takes the folder name. The root
  ///   entry takes the frontmatter `name` of its document, or gives one
  ///   warning when it has none.
  func entry(atFolder folder: String, kind: EntryKind) -> Diagnosed<ResolvedEntry?> {
    if let name = CatalogPath.lastComponent(of: folder) {
      return Diagnosed(value: ResolvedEntry(name: name, path: folder))
    }
    let document = kind.documentName(in: layout)
    do {
      guard let name = try rootEntryName(documentName: document) else {
        let message = "The root \(document) has no frontmatter name that is one folder name. The resolver skips it."
        return Diagnosed(value: nil, diagnostics: [diagnostic(saying: message)])
      }
      return Diagnosed(value: ResolvedEntry(name: name, path: folder))
    } catch {
      return Diagnosed(value: nil, diagnostics: [readFailure(atPath: document, error: error)])
    }
  }

  /// Reads the frontmatter `name` of a document at the root of the tree.
  ///
  /// The frontmatter is the text between the `---` fences, parsed as YAML.
  /// A document with no frontmatter, a frontmatter that does not parse, and
  /// a `name` that is not a text value each give no name.
  ///
  /// - Parameter documentName: The name of the document.
  /// - Returns: The name, or `nil` when the file has no name that is one
  ///   folder name.
  /// - Throws: The error of the file read.
  func rootEntryName(documentName: String) throws -> String? {
    guard let data = try source.contents(atPath: documentName) else {
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

  // MARK: - The selection

  /// Keeps one entry for each name.
  ///
  /// The walk gives the entries in scan order, thus the first entry of a
  /// name is the shallower one, and at the same depth the first in path
  /// order.
  ///
  /// - Parameters:
  ///   - entries: The entries of one kind, in scan order.
  ///   - kind: Whether the entries are skills or agents.
  /// - Returns: The winning entries, in scan order. Each losing entry gives
  ///   one warning.
  func deduplicated(_ entries: [ResolvedEntry], kind: EntryKind) -> Diagnosed<[ResolvedEntry]> {
    var winners: [String: ResolvedEntry] = [:]
    var kept: [ResolvedEntry] = []
    var diagnostics: [MarketplaceDiagnostic] = []
    for entry in entries {
      guard let winner = winners[entry.name] else {
        winners[entry.name] = entry
        kept.append(entry)
        continue
      }
      diagnostics.append(duplicateDiagnostic(loser: entry, winner: winner, kind: kind))
    }
    return Diagnosed(value: kept, diagnostics: diagnostics)
  }

  /// Keeps the skills that a selection names.
  ///
  /// - Parameters:
  ///   - skills: The skills, in scan order.
  ///   - selection: The host selection.
  /// - Returns: The selected skills, in scan order. Each selected name that
  ///   no skill has gives one warning.
  func selectedSkills(_ skills: [ResolvedEntry], by selection: SkillSelection) -> Diagnosed<[ResolvedEntry]> {
    guard case .skills(let names) = selection else {
      return Diagnosed(value: skills)
    }
    let wanted = Set(names)
    let known = Set(skills.map(\.name))
    return Diagnosed(
      value: skills.filter { wanted.contains($0.name) },
      diagnostics: names.filter { !known.contains($0) }.map { name in
        diagnostic(saying: #"The selected skill "\#(name)" is not in the marketplace."#)
      })
  }

  /// Removes each skill whose name is reserved at the layer root: the name
  /// of the agents folder.
  ///
  /// - Parameter skills: The selected skills, in scan order.
  /// - Returns: The skills that the snapshot can hold. Each removed skill
  ///   gives one warning.
  func unreserved(skills: [ResolvedEntry]) -> Diagnosed<[ResolvedEntry]> {
    let isReserved: (ResolvedEntry) -> Bool = { $0.name == MarketplaceLayer.agentsDirectoryName }
    return Diagnosed(
      value: skills.filter { !isReserved($0) },
      diagnostics: skills.filter(isReserved).map { reservedNameDiagnostic(skill: $0) })
  }

  // MARK: - The items of a folder

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

  /// Tells whether an item is the document that marks its folder as an
  /// entry of one kind.
  ///
  /// - Parameters:
  ///   - entry: The item.
  ///   - kind: The kind of entry.
  /// - Returns: `true` for a regular file whose name is the document name of
  ///   the kind. The match is exact. A symbolic link with that name is not a
  ///   document.
  func isDocument(_ entry: CatalogTreeEntry, of kind: EntryKind) -> Bool {
    guard entry.name == kind.documentName(in: layout), case .file = entry.kind else {
      return false
    }
    return true
  }

  /// Tells whether the walk reads into an item as a folder.
  ///
  /// - Parameter entry: The item.
  /// - Returns: `true` for a real folder whose name the layout does not
  ///   exclude. A symbolic link and a submodule are never read.
  func isSubfolder(_ entry: CatalogTreeEntry) -> Bool {
    guard !layout.excludedDirectoryNames.contains(entry.name), case .directory = entry.kind else {
      return false
    }
    return true
  }

  /// Gives one warning for each agent file of the old layout in a folder.
  ///
  /// - Parameters:
  ///   - folder: A folder that is no entry.
  ///   - entries: The items of the folder.
  /// - Returns: One warning for each regular `.md` file of the folder, when
  ///   the folder has the name ``MarketplaceLayer/agentsDirectoryName``.
  ///   Another folder gives none.
  func oldAgentFileDiagnostics(inFolder folder: String, entries: [CatalogTreeEntry]) -> [MarketplaceDiagnostic] {
    guard CatalogPath.lastComponent(of: folder) == MarketplaceLayer.agentsDirectoryName else {
      return []
    }
    return entries.compactMap { entry in
      guard case .file = entry.kind, entry.name.hasSuffix(Self.oldAgentFileExtension),
        entry.name.count > Self.oldAgentFileExtension.count
      else {
        return nil
      }
      return oldAgentFileDiagnostic(name: entry.name, inFolder: folder)
    }
  }

  // MARK: - Diagnostics

  /// Makes a warning about this marketplace.
  ///
  /// - Parameter message: The text of the diagnostic.
  /// - Returns: The warning. The store adds the marketplace to it.
  func diagnostic(saying message: String) -> MarketplaceDiagnostic {
    MarketplaceDiagnostic(severity: .warning, marketplaceID: nil, message: message)
  }

  /// Makes the error for a path that the source cannot read.
  ///
  /// - Parameters:
  ///   - path: The path in the tree.
  ///   - error: The error of the source.
  /// - Returns: An error diagnostic.
  func readFailure(atPath path: String, error: any Error) -> MarketplaceDiagnostic {
    MarketplaceDiagnostic(
      severity: .error, marketplaceID: nil,
      message: #"The resolver cannot read "\#(CatalogPath.display(path: path))": \#(error)"#)
  }

  /// Makes the warning for a folder that holds the skill document and the
  /// agent document.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: A warning that names the folder and the two documents.
  func twoDocumentsDiagnostic(folder: String) -> MarketplaceDiagnostic {
    let documents = EntryKind.allCases.map { $0.documentName(in: layout) }.joined(separator: " and ")
    return diagnostic(
      saying:
        #"The folder "\#(CatalogPath.display(path: folder))" holds \#(documents). A folder is one skill or one agent, thus the resolver skips it."#
    )
  }

  /// Makes the warning for an entry that loses to an entry of the same kind
  /// with the same name.
  ///
  /// - Parameters:
  ///   - loser: The entry that the resolver does not use.
  ///   - winner: The entry that the resolver uses.
  ///   - kind: Whether the entries are skills or agents.
  /// - Returns: A warning that names the two paths.
  func duplicateDiagnostic(loser: ResolvedEntry, winner: ResolvedEntry, kind: EntryKind) -> MarketplaceDiagnostic {
    let loserPath = CatalogPath.display(path: loser.path)
    let winnerPath = CatalogPath.display(path: winner.path)
    return diagnostic(
      saying:
        #"Two \#(kind.pluralNoun) have the name "\#(winner.name)": "\#(loserPath)" and "\#(winnerPath)". The resolver uses "\#(winnerPath)"."#
    )
  }

  /// Makes the warning for a skill whose name is reserved at the layer
  /// root.
  ///
  /// - Parameter skill: The skill that the resolver does not use.
  /// - Returns: A warning that names the skill folder and the reserved name.
  func reservedNameDiagnostic(skill: ResolvedEntry) -> MarketplaceDiagnostic {
    diagnostic(
      saying:
        #"The skill "\#(CatalogPath.display(path: skill.path))" has the name "\#(skill.name)", which a layer root keeps for the agent folders. The resolver skips it."#
    )
  }

  /// Makes the warning for an agent file of the old layout.
  ///
  /// - Parameters:
  ///   - name: The file name, for example `planner.md`.
  ///   - folder: The agents folder that holds the file.
  /// - Returns: A warning that names the file and the path to move it to.
  func oldAgentFileDiagnostic(name: String, inFolder folder: String) -> MarketplaceDiagnostic {
    let agentFolder = CatalogPath.child(named: String(name.dropLast(Self.oldAgentFileExtension.count)), of: folder)
    let target = CatalogPath.child(named: MarketplaceLayer.agentDocumentName, of: agentFolder)
    return diagnostic(
      saying:
        #"The agent file "\#(CatalogPath.child(named: name, of: folder))" is in the old layout. Move it to "\#(target)". The resolver skips it."#
    )
  }
}
