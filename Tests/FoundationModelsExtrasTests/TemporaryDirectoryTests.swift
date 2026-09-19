import FixtureSupport
import Foundation
import Testing

/// Proves `TemporaryDirectory.make()`: each call makes a new empty folder,
/// resolved to its canonical path.
@Suite("Temporary directory")
struct TemporaryDirectoryTests {
  @Test func makeGivesAnExistingEmptyDirectory() throws {
    let directory = try TemporaryDirectory.make()
    defer { try? FileManager.default.removeItem(at: directory) }

    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  @Test func twoCallsGiveDifferentDirectories() throws {
    let first = try TemporaryDirectory.make()
    defer { try? FileManager.default.removeItem(at: first) }
    let second = try TemporaryDirectory.make()
    defer { try? FileManager.default.removeItem(at: second) }

    #expect(first != second)
  }

  @Test func theDirectoryIsCanonical() throws {
    let directory = try TemporaryDirectory.make()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(directory == directory.canonicalDirectory)
  }
}
