import FixtureSupport
import Foundation
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `PathConfinement.relativePath(of:in:)`: the path of a
/// candidate relative to a root, after the symbolic links of both are
/// resolved, or `nil` when the candidate is not under the root.
///
/// Each test makes its own throwaway tree with `TemporaryDirectory`, so the
/// symbolic links and the files are real.
@Suite struct PathConfinementTests {
  /// The path of the reference file, relative to the root of each fixture.
  private static let referencePath = "references/changelog.md"

  /// The name of the root folder of each fixture.
  private static let rootName = "release-notes"

  /// The folder that holds the root folder in the `/tmp` test.
  private static let temporaryFolder = "/tmp"

  /// The prefix that macOS puts in front of `/tmp` when it resolves the link.
  private static let privatePrefix = "/private"

  /// A throwaway tree: a parent folder that holds the root folder, and the
  /// reference file under the root.
  private struct Fixture {
    /// The folder that holds the root.
    let parent: URL

    /// The root that each test gives to `relativePath(of:in:)`.
    let root: URL

    /// Makes the tree under `parent`.
    ///
    /// - Parameter parent: The folder that holds the root.
    /// - Throws: The error of a folder or file write.
    init(parent: URL) throws {
      self.parent = parent
      root = parent.appendingPathComponent(PathConfinementTests.rootName, isDirectory: true)
      try write("changelog", to: PathConfinementTests.referencePath, in: root)
    }

    /// Writes `text` to `relativePath` under `folder`, and makes each
    /// missing folder.
    ///
    /// - Parameters:
    ///   - text: The text of the file.
    ///   - relativePath: The path of the file, relative to `folder`.
    ///   - folder: The folder that holds the file.
    /// - Returns: The URL of the file.
    /// - Throws: The error of a folder or file write.
    @discardableResult
    func write(_ text: String, to relativePath: String, in folder: URL) throws -> URL {
      let file = folder.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: file, atomically: true, encoding: .utf8)
      return file
    }
  }

  @Test func aFileInTheRootGivesItsPathRelativeToTheRoot() throws {
    let fixture = try Fixture(parent: TemporaryDirectory.make())
    let candidate = fixture.root.appendingPathComponent(Self.referencePath)

    #expect(PathConfinement.relativePath(of: candidate, in: fixture.root) == Self.referencePath)
  }

  @Test func thePrivateTmpFormOfAFileGivesTheSameRelativePath() throws {
    let parent = URL(fileURLWithPath: Self.temporaryFolder, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let fixture = try Fixture(parent: parent)
    let privateCandidate = URL(
      fileURLWithPath: Self.privatePrefix + fixture.root.appendingPathComponent(Self.referencePath).path)

    #expect(PathConfinement.relativePath(of: privateCandidate, in: fixture.root) == Self.referencePath)
  }

  @Test func theRootItselfGivesNil() throws {
    let fixture = try Fixture(parent: TemporaryDirectory.make())

    #expect(PathConfinement.relativePath(of: fixture.root, in: fixture.root) == nil)
  }

  @Test func aSiblingFolderWhoseNameStartsWithTheRootNameGivesNil() throws {
    let fixture = try Fixture(parent: TemporaryDirectory.make())
    let sibling = fixture.parent.appendingPathComponent(Self.rootName + "-extra", isDirectory: true)
    let candidate = try fixture.write("other", to: "x", in: sibling)

    #expect(PathConfinement.relativePath(of: candidate, in: fixture.root) == nil)
  }

  @Test func aPathOutsideTheRootGivesNil() throws {
    let fixture = try Fixture(parent: TemporaryDirectory.make())
    let candidate = try fixture.write("other", to: "outside.md", in: fixture.parent)

    #expect(PathConfinement.relativePath(of: candidate, in: fixture.root) == nil)
  }

  @Test func aDotDotPathThatLeavesTheRootGivesNil() throws {
    let fixture = try Fixture(parent: TemporaryDirectory.make())
    try fixture.write("other", to: "outside.md", in: fixture.parent)
    let candidate = fixture.root.appendingPathComponent("references/../../outside.md")

    #expect(PathConfinement.relativePath(of: candidate, in: fixture.root) == nil)
  }

  @Test func aSymbolicLinkInTheRootThatPointsOutsideGivesNil() throws {
    let fixture = try Fixture(parent: TemporaryDirectory.make())
    let outside = try fixture.write("secret", to: "secret.md", in: fixture.parent)
    let link = fixture.root.appendingPathComponent("references/secret.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    #expect(PathConfinement.relativePath(of: link, in: fixture.root) == nil)
  }
}
