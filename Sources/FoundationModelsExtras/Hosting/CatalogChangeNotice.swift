/// The kind of a catalog that a tool lists in its description, for example
/// the skills of the `skills` tool.
///
/// The set of kinds is open. This package gives the kinds of the tooling as
/// static values. A host gives its own kinds with ``init(_:)``. Two kinds
/// are equal when their raw values are equal.
public struct CatalogKind: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    /// The name of the kind, for example `skills`.
    public let rawValue: String

    /// Makes a kind with the name `rawValue`.
    ///
    /// - Parameter rawValue: The name of the kind.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Makes a kind with the name `rawValue`.
    ///
    /// - Parameter rawValue: The name of the kind.
    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    /// Makes a kind from a string literal.
    ///
    /// - Parameter value: The name of the kind.
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    /// Makes a kind from the encoded name.
    ///
    /// - Parameter decoder: The decoder.
    /// - Throws: When the value is not a string.
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    /// Encodes the name of the kind as one string.
    ///
    /// - Parameter encoder: The encoder.
    /// - Throws: The error of the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The name of the kind.
    public var description: String { rawValue }

    /// The skills of the `skills` tool.
    public static let skills = CatalogKind("skills")

    /// The agents of the `agents` tool.
    public static let agents = CatalogKind("agents")
}

/// One entry of a catalog, as a tool lists it in its description: a name and
/// a one-line description. It never holds the body of the entry.
public struct CatalogEntry: Sendable, Codable, Hashable {
    /// The name of the entry, the name that the model gives to the tool.
    public let name: String

    /// The one-line description of the entry.
    public let description: String

    /// Makes an entry.
    ///
    /// - Parameters:
    ///   - name: The name of the entry.
    ///   - description: The one-line description of the entry.
    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// A change of a catalog during a session: the entries that were added,
/// removed or changed.
///
/// A tool reads its catalog one time, when it is made, and lists it in its
/// description. The description never changes during a session, because a
/// change throws away the cached prompt. When the catalog reloads, the tool
/// package compares the old and the new catalog with
/// ``init(kind:from:to:)``, and posts the notice through a
/// ``CatalogNoticeBoard``. The model reads ``text``.
///
/// A notice holds only names and one-line descriptions, never the body of an
/// entry.
public struct CatalogChangeNotice: Sendable, Codable, Hashable {
    /// The kind of the catalog.
    public let kind: CatalogKind

    /// The new entries, in the order of the new catalog.
    public let added: [CatalogEntry]

    /// The entries that left the catalog, in the order of the old catalog.
    public let removed: [CatalogEntry]

    /// The entries whose description changed, with the new description, in
    /// the order of the new catalog.
    public let changed: [CatalogEntry]

    /// Makes a notice from its lists.
    ///
    /// - Parameters:
    ///   - kind: The kind of the catalog.
    ///   - added: The new entries.
    ///   - removed: The entries that left the catalog.
    ///   - changed: The entries whose description changed, with the new
    ///     description.
    public init(kind: CatalogKind, added: [CatalogEntry], removed: [CatalogEntry], changed: [CatalogEntry]) {
        self.kind = kind
        self.added = added
        self.removed = removed
        self.changed = changed
    }

    /// Compares two catalogs by name, or gives `nil` when nothing changed.
    ///
    /// An entry whose name is only in `new` is added, an entry whose name is
    /// only in `old` is removed, and an entry whose description differs is
    /// changed. The order of the entries in a catalog is not a change. When a
    /// catalog has two entries with one name, the first one counts.
    ///
    /// - Parameters:
    ///   - kind: The kind of the catalog.
    ///   - old: The catalog that the session knows.
    ///   - new: The catalog after the reload.
    public init?(kind: CatalogKind, from old: [CatalogEntry], to new: [CatalogEntry]) {
        let old = Self.firstOfEachName(old)
        let new = Self.firstOfEachName(new)
        let oldByName = Dictionary(uniqueKeysWithValues: old.map { ($0.name, $0) })
        let newNames = Set(new.map(\.name))
        let added = new.filter { oldByName[$0.name] == nil }
        let changed = new.filter { entry in oldByName[entry.name].map { $0 != entry } ?? false }
        let removed = old.filter { !newNames.contains($0.name) }
        guard !added.isEmpty || !removed.isEmpty || !changed.isEmpty else { return nil }
        self.init(kind: kind, added: added, removed: removed, changed: changed)
    }

    /// What the model reads, for example:
    ///
    /// ```
    /// Skills changed. New: `x`: does x. Removed: `y`.
    /// ```
    ///
    /// A new or changed entry gives its name and its description, and a
    /// removed entry gives only its name. A section with no entries is left
    /// out.
    public var text: String {
        let title = kind.rawValue.prefix(1).uppercased() + kind.rawValue.dropFirst()
        var sentences = ["\(title) changed."]
        if !added.isEmpty {
            sentences.append("New: " + added.map(Self.describe).joined(separator: "; ") + ".")
        }
        if !changed.isEmpty {
            sentences.append("Changed: " + changed.map(Self.describe).joined(separator: "; ") + ".")
        }
        if !removed.isEmpty {
            sentences.append("Removed: " + removed.map { "`\($0.name)`" }.joined(separator: ", ") + ".")
        }
        return sentences.joined(separator: " ")
    }

    /// The name of `entry` in code font, then its description when it has
    /// one.
    ///
    /// - Parameter entry: The entry.
    /// - Returns: The text of the entry.
    private static func describe(_ entry: CatalogEntry) -> String {
        entry.description.isEmpty ? "`\(entry.name)`" : "`\(entry.name)`: \(entry.description)"
    }

    /// The first entry of each name, in catalog order.
    ///
    /// - Parameter catalog: The catalog.
    /// - Returns: The catalog with no second entry of a name.
    private static func firstOfEachName(_ catalog: [CatalogEntry]) -> [CatalogEntry] {
        var seen = Set<String>()
        return catalog.filter { seen.insert($0.name).inserted }
    }
}
