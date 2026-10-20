import FoundationModelsExtras
import Foundation
import Testing

/// Exercises ``CatalogChangeNotice``: the compare of two catalogs, and the
/// text that the model reads.
@Suite("Catalog change notice: the compare of two catalogs and its text")
struct CatalogChangeNoticeTests {
    /// An entry named `name` with the description `description`.
    private static func entry(_ name: String, _ description: String) -> CatalogEntry {
        CatalogEntry(name: name, description: description)
    }

    // MARK: - The compare

    @Test("the same catalog gives no notice, also in a new order")
    func theSameCatalogGivesNone() {
        let old = [Self.entry("a", "does a"), Self.entry("b", "does b")]

        #expect(CatalogChangeNotice(kind: .skills, from: old, to: old) == nil)
        #expect(CatalogChangeNotice(kind: .skills, from: old, to: old.reversed()) == nil)
        #expect(CatalogChangeNotice(kind: .agents, from: [], to: []) == nil)
    }

    @Test("an added, a removed and a changed entry each go to their own list")
    func eachChangeGoesToItsList() throws {
        let old = [Self.entry("kept", "same"), Self.entry("gone", "was here"), Self.entry("edited", "old text")]
        let new = [Self.entry("kept", "same"), Self.entry("edited", "new text"), Self.entry("fresh", "is new")]

        let notice = try #require(CatalogChangeNotice(kind: .skills, from: old, to: new))

        #expect(notice.kind == .skills)
        #expect(notice.added == [Self.entry("fresh", "is new")])
        #expect(notice.removed == [Self.entry("gone", "was here")])
        #expect(notice.changed == [Self.entry("edited", "new text")])
    }

    @Test("added and changed keep the new order, removed keeps the old order, and the first entry of a name wins")
    func theOrderRules() throws {
        let old = [
            Self.entry("r2", "x"), Self.entry("c2", "old"), Self.entry("r1", "x"), Self.entry("c1", "old"),
            Self.entry("dup", "first"), Self.entry("dup", "second"),
        ]
        let new = [
            Self.entry("a2", "x"), Self.entry("c1", "new"), Self.entry("a1", "x"), Self.entry("c2", "new"),
            Self.entry("dup", "first"), Self.entry("a1", "later copy"),
        ]

        let notice = try #require(CatalogChangeNotice(kind: .agents, from: old, to: new))

        #expect(notice.added == [Self.entry("a2", "x"), Self.entry("a1", "x")])
        #expect(notice.changed == [Self.entry("c1", "new"), Self.entry("c2", "new")])
        #expect(notice.removed == [Self.entry("r2", "x"), Self.entry("r1", "x")])
    }

    // MARK: - The text

    @Test("the text names the kind and gives each section, with the description of each new or changed entry")
    func theTextOfEachSection() throws {
        let notice = CatalogChangeNotice(
            kind: .skills,
            added: [Self.entry("x", "does x"), Self.entry("w", "does w")],
            removed: [Self.entry("y", "did y"), Self.entry("v", "did v")],
            changed: [Self.entry("z", "now does z")]
        )

        #expect(
            notice.text
                == "Skills changed. New: `x`: does x; `w`: does w. Changed: `z`: now does z. Removed: `y`, `v`.")
    }

    @Test("a section with no entries is left out")
    func anEmptySectionIsLeftOut() throws {
        let added = try #require(CatalogChangeNotice(kind: .agents, from: [], to: [Self.entry("helper", "helps")]))
        let removed = try #require(CatalogChangeNotice(kind: .agents, from: [Self.entry("helper", "helps")], to: []))

        #expect(added.text == "Agents changed. New: `helper`: helps.")
        #expect(removed.text == "Agents changed. Removed: `helper`.")
    }

    @Test("an entry with an empty description gives only its name")
    func anEmptyDescriptionGivesTheName() throws {
        let notice = try #require(CatalogChangeNotice(kind: .skills, from: [], to: [Self.entry("bare", "")]))

        #expect(notice.text == "Skills changed. New: `bare`.")
    }

    @Test("a kind of a host gives its own name in the text")
    func aHostKindNamesItself() throws {
        let notice = try #require(
            CatalogChangeNotice(kind: CatalogKind("prompts"), from: [], to: [Self.entry("p", "a prompt")]))

        #expect(notice.text == "Prompts changed. New: `p`: a prompt.")
    }

    // MARK: - Coding

    @Test("a notice survives a Codable round trip, and a kind encodes as one string")
    func aCodableRoundTrip() throws {
        let notice = try #require(
            CatalogChangeNotice(
                kind: .skills, from: [Self.entry("old", "o"), Self.entry("c", "1")],
                to: [Self.entry("new", "n"), Self.entry("c", "2")]))

        let decoded = try JSONDecoder().decode(CatalogChangeNotice.self, from: JSONEncoder().encode(notice))
        let kind = try JSONEncoder().encode(CatalogKind.agents)

        #expect(decoded == notice)
        #expect(String(decoding: kind, as: UTF8.self) == "\"agents\"")
        #expect(try JSONDecoder().decode(CatalogKind.self, from: kind) == .agents)
    }
}
