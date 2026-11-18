import Foundation
import Testing

@testable import FoundationModelsExtras

/// `URL.comparablePath` gives one path for each folder, so that two URLs of
/// the same folder compare equal.
@Suite("URL.comparablePath: one path for each folder")
struct URLComparablePathTests {
    /// A folder that does not exist on the disk.
    private static let folder = URL(fileURLWithPath: "/tmp/comparable-path/folder", isDirectory: true)

    @Test("a trailing slash does not change the path")
    func aTrailingSlashDoesNotChangeThePath() {
        let withSlash = URL(fileURLWithPath: Self.folder.path + "/")

        #expect(withSlash.comparablePath == Self.folder.comparablePath)
    }

    @Test("a dot dot component is removed")
    func aDotDotComponentIsRemoved() {
        let roundTrip = Self.folder.appendingPathComponent("child").appendingPathComponent("..")

        #expect(roundTrip.comparablePath == Self.folder.comparablePath)
    }

    @Test("a symbolic link gives the path of the folder it links to")
    func aSymbolicLinkGivesThePathOfItsTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let realFolder = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFolder)

        #expect(link.comparablePath == realFolder.comparablePath)
    }
}
