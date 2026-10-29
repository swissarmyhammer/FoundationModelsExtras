import Foundation
import FoundationModelsExtras
import Testing

/// ``ModelRef``: the `repo@revision` name of a model. These tests came from
/// the `CoreTypes` suite of FoundationModelsRouter with the type (decision
/// 2026-09-26).
///
/// The suite imports the module plainly rather than with `@testable`, so it
/// exercises the same surface a consumer package sees.
@Suite("ModelRef")
struct ModelRefTests {
    @Test("a bare string literal is a ModelRef with no revision")
    func modelRefStringLiteral() {
        let ref: ModelRef = "mlx-community/Qwen2.5-Coder-32B-Instruct-8bit"

        #expect(ref.repo == "mlx-community/Qwen2.5-Coder-32B-Instruct-8bit")
        #expect(ref.revision == nil)
    }

    @Test("a revision-pinned literal parses repo and revision")
    func modelRefRevisionPinned() {
        let ref: ModelRef = "org/repo@abc123"

        #expect(ref.repo == "org/repo")
        #expect(ref.revision == "abc123")
    }

    @Test("ModelRef.init(_:) splits on the first @ only")
    func modelRefSplitsOnTheFirstSeparator() {
        let ref = ModelRef("org/repo@rev@more")

        #expect(ref.repo == "org/repo")
        #expect(ref.revision == "rev@more")
        #expect(ref.stringValue == "org/repo@rev@more")
    }

    @Test("ModelRef Codable round-trips the repo and revision")
    func modelRefCodableRoundTrip() throws {
        let ref: ModelRef = "org/repo@abc123"

        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = try encoder.encode(ref)
        let decoded = try JSONDecoder().decode(ModelRef.self, from: data)

        #expect(decoded == ref)
        #expect(String(decoding: data, as: UTF8.self) == "\"org/repo@abc123\"")
    }

    @Test("ModelRef.init(repo:revision:) sets fields and matches the string-literal form")
    func modelRefMemberwiseInitWithRevision() {
        let ref = ModelRef(repo: "org/repo", revision: "abc123")
        let literal: ModelRef = "org/repo@abc123"

        #expect(ref.repo == "org/repo")
        #expect(ref.revision == "abc123")
        #expect(ref.stringValue == "org/repo@abc123")
        #expect(ref == literal)
    }

    @Test("ModelRef.init(repo:revision:) defaults revision to nil and matches the string-literal form")
    func modelRefMemberwiseInitWithoutRevision() {
        let ref = ModelRef(repo: "org/repo")
        let literal: ModelRef = "org/repo"

        #expect(ref.repo == "org/repo")
        #expect(ref.revision == nil)
        #expect(ref.stringValue == "org/repo")
        #expect(ref == literal)
    }

    /// The forms of one reference to the default revision: no revision, an
    /// empty revision, and the revision `main`, from each initializer.
    private static let defaultRevisionForms: [ModelRef] = [
        ModelRef("org/repo"),
        ModelRef("org/repo@"),
        ModelRef("org/repo@main"),
        ModelRef(repo: "org/repo", revision: nil),
        ModelRef(repo: "org/repo", revision: ""),
        ModelRef(repo: "org/repo", revision: "main"),
    ]

    @Test("no revision, an empty revision and the revision main are one ModelRef", arguments: defaultRevisionForms)
    func defaultRevisionFormsAreOneReference(_ ref: ModelRef) {
        let unpinned = ModelRef("org/repo")

        #expect(ref == unpinned)
        #expect(ref.hashValue == unpinned.hashValue)
        #expect(ref.revision == nil)
        #expect(ref.stringValue == "org/repo")
    }

    @Test("a Codable round trip of each default-revision form gives the unpinned ModelRef")
    func defaultRevisionCodableRoundTrip() throws {
        for text in ["org/repo", "org/repo@", "org/repo@main"] {
            let data = try JSONEncoder().encode(text)
            let decoded = try JSONDecoder().decode(ModelRef.self, from: data)

            #expect(decoded == ModelRef("org/repo"))
            #expect(decoded.revision == nil)
        }
    }

    @Test("a real revision stays different from the unpinned ModelRef")
    func realRevisionIsDifferent() throws {
        let pinned = ModelRef("org/repo@abc123")

        #expect(pinned != ModelRef("org/repo"))
        #expect(pinned != ModelRef("org/repo@main"))
        #expect(pinned.stringValue == "org/repo@abc123")
        let decoded = try JSONDecoder().decode(ModelRef.self, from: JSONEncoder().encode(pinned))
        #expect(decoded == pinned)
    }

    @Test("a ModelRef with no drafter names none")
    func noDrafter() {
        #expect(ModelRef("org/repo").drafter == nil)
    }

    @Test("ModelRef.init(repo:revision:drafter:) keeps the MTP drafter beside the target")
    func memberwiseInitWithDrafter() {
        let ref = ModelRef(repo: "org/target", revision: "abc123", drafter: "org/drafter@def456")

        #expect(ref.repo == "org/target")
        #expect(ref.revision == "abc123")
        #expect(ref.drafter == ModelRef("org/drafter@def456"))
        #expect(ref.stringValue == "org/target@abc123")
    }

    @Test("a drafter makes a different ModelRef from the same target with no drafter")
    func drafterIsPartOfTheIdentity() {
        let plain = ModelRef("org/target")
        let speculating = ModelRef(repo: "org/target", drafter: "org/drafter")

        #expect(speculating != plain)
        #expect(Set([plain, speculating]).count == 2)
    }

    @Test("a mapping with repo and drafter decodes to a ModelRef with a drafter")
    func mappingDecodesTheDrafter() throws {
        let json = #"{"repo": "org/target@abc123", "drafter": "org/drafter@def456"}"#

        let decoded = try JSONDecoder().decode(ModelRef.self, from: Data(json.utf8))

        #expect(decoded == ModelRef(repo: "org/target", revision: "abc123", drafter: "org/drafter@def456"))
    }

    @Test("a mapping with repo alone decodes to the ModelRef of the string form")
    func mappingWithoutDrafterIsTheStringForm() throws {
        let decoded = try JSONDecoder().decode(ModelRef.self, from: Data(#"{"repo": "org/target"}"#.utf8))

        #expect(decoded == ModelRef("org/target"))
    }

    @Test("a ModelRef with a drafter round-trips through the mapping form")
    func drafterCodableRoundTrip() throws {
        let ref = ModelRef(repo: "org/target", drafter: "org/drafter@def456")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]

        let data = try encoder.encode(ref)

        #expect(String(decoding: data, as: UTF8.self) == #"{"drafter":"org/drafter@def456","repo":"org/target"}"#)
        #expect(try JSONDecoder().decode(ModelRef.self, from: data) == ref)
    }
}
