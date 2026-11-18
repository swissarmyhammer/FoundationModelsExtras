import Foundation
import Testing
import ULID

@testable import FoundationModelsExtras

/// ``SessionReference`` finds the session that a typed reference names.
@Suite("SessionReference: the session that a typed reference names")
struct SessionReferenceTests {
    /// The text of the id of the first sample session.
    private static let firstIDText = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    /// The text of an id that has the same short id as ``firstIDText``.
    private static let sameShortIDText = "01BX5ZZKBKACTAV9WEQ69G5FAV"

    /// A working folder that is not ``SessionFixtures/folder``.
    private static let otherFolder = URL(fileURLWithPath: "/tmp/other", isDirectory: true)

    /// Makes a sample session.
    ///
    /// - Parameters:
    ///   - id: The session id. The default is a new id.
    ///   - title: The title of the session. The default is `nil`.
    ///   - folder: The working folder. The default is ``SessionFixtures/folder``.
    ///   - state: The work state. The default is ``SessionState/idle``.
    /// - Returns: The summary of the session.
    private static func session(
        id: ULID = ULID(),
        title: String? = nil,
        folder: URL = SessionFixtures.folder,
        state: SessionState = .idle
    ) -> SessionSummary {
        var summary = SessionFixtures.summary(id: id)
        summary.title = title
        summary.workingDirectory = folder
        summary.state = state
        return summary
    }

    /// Parses the text of an id.
    ///
    /// - Parameter text: The text of the id.
    /// - Returns: The id.
    private static func id(_ text: String) throws -> ULID {
        try #require(ULID(ulidString: text))
    }

    @Test("a full id in upper case resolves")
    func aFullIDInUpperCaseResolves() {
        let target = Self.session()

        let result = SessionReference.resolve(
            target.id.ulidString.uppercased(), sourceFolder: nil, among: [Self.session(), target])

        #expect(result == .session(target))
    }

    @Test("a full id in lower case resolves")
    func aFullIDInLowerCaseResolves() {
        let target = Self.session()

        let result = SessionReference.resolve(
            target.id.ulidString.lowercased(), sourceFolder: nil, among: [Self.session(), target])

        #expect(result == .session(target))
    }

    @Test("a leading @ gives the same result as the text without it")
    func aLeadingAtSignChangesNothing() {
        let target = Self.session(title: "Write the docs")
        let summaries = [Self.session(title: "Fix the build"), target]

        let withAtSign = SessionReference.resolve("@write-the-docs", sourceFolder: nil, among: summaries)
        let withoutAtSign = SessionReference.resolve("write-the-docs", sourceFolder: nil, among: summaries)

        #expect([withAtSign, withoutAtSign] == [.session(target), .session(target)])
    }

    @Test("white space around the text has no effect")
    func whiteSpaceAroundTheTextHasNoEffect() {
        let target = Self.session(title: "Write the docs")

        let result = SessionReference.resolve("  @write-the-docs \n", sourceFolder: nil, among: [target])

        #expect(result == .session(target))
    }

    @Test("an id that is also the slug of an other session gives the session with the id")
    func anIDWinsOverASlug() throws {
        let target = Self.session(id: try Self.id(Self.firstIDText))
        let slugTwin = Self.session(title: Self.firstIDText)

        let result = SessionReference.resolve(Self.firstIDText, sourceFolder: nil, among: [slugTwin, target])

        #expect(result == .session(target))
    }

    @Test("a full id with no session gives none, also when a slug has that text")
    func aFullIDWithNoSessionGivesNone() {
        let slugTwin = Self.session(title: Self.firstIDText)

        let result = SessionReference.resolve(Self.firstIDText, sourceFolder: nil, among: [slugTwin])

        #expect(result == .none)
    }

    @Test("a short id resolves, in any letter case")
    func aShortIDResolves() {
        let target = Self.session(title: "Fix the build")

        let result = SessionReference.resolve(
            target.shortID.uppercased(), sourceFolder: nil, among: [Self.session(), target])

        #expect(result == .session(target))
    }

    @Test("a short id that two sessions share gives ambiguous, in the order of the summaries")
    func aSharedShortIDIsAmbiguous() throws {
        let first = Self.session(id: try Self.id(Self.firstIDText))
        let second = Self.session(id: try Self.id(Self.sameShortIDText))

        let result = SessionReference.resolve(first.shortID, sourceFolder: nil, among: [second, first])

        #expect(result == .ambiguous([second, first]))
    }

    @Test("a slug resolves, in any letter case")
    func aSlugResolves() {
        let target = Self.session(title: "Write the docs")

        let result = SessionReference.resolve("Write-The-Docs", sourceFolder: nil, among: [target])

        #expect(result == .session(target))
    }

    @Test("a slug in the source folder wins over the same slug in an other folder")
    func aSlugInTheSourceFolderWins() {
        let elsewhere = Self.session(title: "Fix the build", folder: Self.otherFolder)
        let local = Self.session(title: "Fix the build")

        let result = SessionReference.resolve(
            "fix-the-build", sourceFolder: SessionFixtures.folder, among: [elsewhere, local])

        #expect(result == .session(local))
    }

    @Test("a short id in an other folder wins over the same text as a slug in the source folder")
    func aShortIDInAnOtherFolderWinsOverASlugInTheSourceFolder() {
        let elsewhere = Self.session(folder: Self.otherFolder)
        let local = Self.session(title: elsewhere.shortID)

        let result = SessionReference.resolve(
            elsewhere.shortID, sourceFolder: SessionFixtures.folder, among: [local, elsewhere])

        #expect(result == .session(elsewhere))
    }

    @Test("the same slug two times in the source folder gives ambiguous")
    func aSlugTwoTimesInTheSourceFolderIsAmbiguous() {
        let first = Self.session(title: "Fix the build")
        let second = Self.session(title: "Fix the build")
        let elsewhere = Self.session(title: "Fix the build", folder: Self.otherFolder)

        let result = SessionReference.resolve(
            "fix-the-build", sourceFolder: SessionFixtures.folder, among: [first, elsewhere, second])

        #expect(result == .ambiguous([first, second]))
    }

    @Test("a slug that is only in an other folder resolves")
    func aSlugOnlyInAnOtherFolderResolves() {
        let elsewhere = Self.session(title: "Fix the build", folder: Self.otherFolder)

        let result = SessionReference.resolve(
            "fix-the-build", sourceFolder: SessionFixtures.folder, among: [Self.session(), elsewhere])

        #expect(result == .session(elsewhere))
    }

    @Test("a source folder with a trailing slash matches the folder of a session")
    func aSourceFolderWithATrailingSlashMatches() {
        let elsewhere = Self.session(title: "Fix the build", folder: Self.otherFolder)
        let local = Self.session(title: "Fix the build")
        let sourceFolder = URL(fileURLWithPath: SessionFixtures.folder.path + "/")

        let result = SessionReference.resolve("fix-the-build", sourceFolder: sourceFolder, among: [elsewhere, local])

        #expect(result == .session(local))
    }

    @Test("a source folder that is a symbolic link matches the folder it links to")
    func aSourceFolderThatIsASymbolicLinkMatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let realFolder = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFolder)
        let elsewhere = Self.session(title: "Fix the build", folder: Self.otherFolder)
        let local = Self.session(title: "Fix the build", folder: realFolder)

        let result = SessionReference.resolve("fix-the-build", sourceFolder: link, among: [elsewhere, local])

        #expect(result == .session(local))
    }

    @Test("an archived session does not match its full id")
    func anArchivedSessionDoesNotMatchItsID() {
        let archived = Self.session(state: .archived)

        let result = SessionReference.resolve(archived.id.ulidString, sourceFolder: nil, among: [archived])

        #expect(result == .none)
    }

    @Test("an archived session does not match its short id")
    func anArchivedSessionDoesNotMatchItsShortID() {
        let archived = Self.session(title: "Fix the build", state: .archived)

        let result = SessionReference.resolve(archived.shortID, sourceFolder: nil, among: [archived])

        #expect(result == .none)
    }

    @Test("an archived session does not match its slug, and does not make the slug ambiguous")
    func anArchivedSessionDoesNotMatchItsSlug() {
        let archived = Self.session(title: "Fix the build", state: .archived)
        let live = Self.session(title: "Fix the build")

        let result = SessionReference.resolve("fix-the-build", sourceFolder: nil, among: [archived, live])

        #expect(result == .session(live))
    }

    @Test("a text that matches no session gives none")
    func noMatchGivesNone() {
        let result = SessionReference.resolve(
            "@nothing-here", sourceFolder: SessionFixtures.folder, among: [Self.session(title: "Fix the build")])

        #expect(result == .none)
    }

    @Test("an empty text gives none")
    func anEmptyTextGivesNone() {
        let result = SessionReference.resolve(" @ ", sourceFolder: nil, among: [Self.session()])

        #expect(result == .none)
    }
}
