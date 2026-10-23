import FixtureSupport
import Foundation
import Testing

@testable import FoundationModelsExtras

/// Proves the save of a `FrontmatterDocument`: the metadata goes between two
/// `---` fences as YAML and the body follows unchanged, a read of the file
/// gives the same metadata and the same body, the save puts its temporary
/// file in the folder of the target and leaves none behind, and a failed save
/// leaves the old file whole.
@Suite("Frontmatter document save")
struct FrontmatterDocumentSaveTests {
  /// The name of the document file in the folder of each test.
  private static let fileName = "SKILL.md"

  /// The seconds since 1970 of ``createdDate``: a whole number, which YAML
  /// writes exactly.
  private static let createdSeconds: TimeInterval = 1_700_000_000

  /// The date of the round trip tests.
  private static let createdDate = Date(timeIntervalSince1970: createdSeconds)

  /// The name of a symbolic link to the document file.
  private static let linkName = "link.md"

  /// The permissions that a new document file gets: the owner reads and
  /// writes, the others read.
  private static let newFileMode = 0o644

  /// Permissions that differ from ``newFileMode``: only the owner reads and
  /// writes.
  private static let ownerOnlyMode = 0o600

  /// The text of the file before a save that fails.
  private static let oldText = "---\ntitle: Old\n---\nold body\n"

  /// A body with lines that are exactly `---`, which must not end the
  /// frontmatter when the file reads back.
  private static let bodyWithFences = "# Notes\n---\ntitle: not metadata\n---\nlast line\n"

  /// The metadata of the tests: a multiline string, a date, a set and an
  /// optional that is `nil`.
  private struct Metadata: Codable, Equatable, Sendable {
    /// A one-line title.
    var title: String

    /// A text of several lines.
    var notes: String

    /// A date.
    var created: Date

    /// A set of tags.
    var tags: Set<String>

    /// An optional value that the tests leave `nil`.
    var owner: String?
  }

  /// A whole-number `Double`, which YAML must not write with an exponent.
  private static let wholeSeconds: Double = 6

  /// A fraction, which YAML must not write with an exponent.
  private static let quarterSeconds: Double = 0.25

  /// A tiny `Double`, whose shortest text in Swift carries an exponent.
  private static let tinySeconds: Double = 0.000_01

  /// A huge `Double`, whose shortest text in Swift carries an exponent.
  private static let hugeSeconds: Double = 100_000_000_000_000_000_000

  /// Doubles that only a text of 17 significant digits, or one at the
  /// edge of the range, gives back exactly.
  private static let hardDoubles: [Double] = [
    0.1 + 0.2, -2.5, tinySeconds, hugeSeconds, wholeSeconds, quarterSeconds,
    .greatestFiniteMagnitude, .leastNonzeroMagnitude, .infinity, -.infinity,
  ]

  /// Floats whose text must be the short text of a `Float`.
  private static let floats: [Float] = [0.1, 0.25, 6]

  /// Metadata of two named `Double` values.
  private struct Timing: Codable, Equatable, Sendable {
    /// A whole number of seconds.
    var grace: Double

    /// A fraction of a second.
    var step: Double
  }

  /// Metadata of a list of `Double` values.
  private struct Doubles: Codable, Equatable, Sendable {
    /// The values.
    var values: [Double]
  }

  /// Metadata of a list of `Float` values.
  private struct Floats: Codable, Equatable, Sendable {
    /// The values.
    var values: [Float]
  }

  /// Metadata whose encode always throws ``failure``.
  private struct UnencodableMetadata: Encodable, Sendable {
    /// The text of the failure.
    static let message = "this metadata does not encode"

    /// The error of each encode. An `EncodingError`, which the YAML encoder
    /// passes on unchanged.
    static var failure: EncodingError {
      .invalidValue(message, EncodingError.Context(codingPath: [], debugDescription: message))
    }

    func encode(to encoder: any Encoder) throws {
      throw Self.failure
    }
  }

  /// The metadata of the round trip tests.
  private static let metadata = Metadata(
    title: "Review",
    notes: "first line\nsecond line\n\nafter a blank line\n",
    created: createdDate,
    tags: ["swift", "yaml", "frontmatter"],
    owner: nil)

  /// Makes a new empty folder and the URL of the document file in it. The
  /// file is not on disk yet.
  ///
  /// - Returns: The folder, which the test removes, and the file.
  /// - Throws: The error of `TemporaryDirectory.make()`.
  private static func makeFile() throws -> (folder: URL, file: URL) {
    let folder = try TemporaryDirectory.make()
    return (folder, folder.appendingPathComponent(fileName))
  }

  /// Reads the file at `url` the way a reader of documents does: the split,
  /// then the YAML decode of the frontmatter.
  ///
  /// - Parameter url: The document file.
  /// - Returns: The decoded metadata, `nil` when the file has no
  ///   frontmatter block, and the body.
  /// - Throws: The error of the read, of the parse or of the decode.
  private static func readBack(_ url: URL) throws -> (metadata: Metadata?, body: String) {
    let split = FrontmatterDocument.split(text: try String(contentsOf: url, encoding: .utf8))
    let metadata = try split.frontmatter.map { try YAMLValue.parse($0).decoded(as: Metadata.self) }
    return (metadata, split.body)
  }

  /// The names in `folder`.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The names of the entries, hidden ones too.
  /// - Throws: The error of the file manager.
  private static func names(in folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path)
  }

  /// The permission bits of the file at `url`.
  ///
  /// - Parameter url: The file.
  /// - Returns: The permissions.
  /// - Throws: The error of the file manager, or of `#require` when the
  ///   attributes hold no permissions.
  private static func mode(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
  }

  @Test func theRenderPutsTheYAMLBetweenFencesAndThenTheBody() throws {
    struct Title: Encodable, Sendable {
      var title: String
    }
    let document = FrontmatterDocument(metadata: Title(title: "Test"), content: "# Body\n")

    #expect(try document.rendered() == "---\ntitle: Test\n---\n# Body\n")
  }

  @Test func aDoubleRendersAsPlainDecimalText() throws {
    let timing = Timing(grace: Self.wholeSeconds, step: Self.quarterSeconds)
    let document = FrontmatterDocument(metadata: timing, content: "")

    #expect(try document.rendered() == "---\ngrace: 6.0\nstep: 0.25\n---\n")
  }

  @Test func aDoubleThatSwiftWritesWithAnExponentRendersWithoutOne() throws {
    let timing = Timing(grace: Self.hugeSeconds, step: Self.tinySeconds)
    let document = FrontmatterDocument(metadata: timing, content: "")

    #expect(
      try document.rendered()
        == "---\ngrace: 100000000000000000000.0\nstep: 0.00001\n---\n")
  }

  @Test func aRenderedDoubleDecodesBackToTheSameValue() throws {
    let numbers = Doubles(values: Self.hardDoubles)
    let text = try FrontmatterDocument(metadata: numbers, content: "").rendered()

    let frontmatter = try #require(FrontmatterDocument.split(text: text).frontmatter)
    #expect(try YAMLValue.parse(frontmatter).decoded(as: Doubles.self) == numbers)
    #expect(!frontmatter.contains(/[0-9][eE][-+]?[0-9]/))
  }

  @Test func aFloatRendersAsItsShortPlainTextAndDecodesBack() throws {
    let numbers = Floats(values: Self.floats)
    let text = try FrontmatterDocument(metadata: numbers, content: "").rendered()

    #expect(text == "---\nvalues:\n- 0.1\n- 0.25\n- 6.0\n---\n")
    let frontmatter = try #require(FrontmatterDocument.split(text: text).frontmatter)
    #expect(try YAMLValue.parse(frontmatter).decoded(as: Floats.self) == numbers)
  }

  @Test func aSavedDocumentReadsBackWithTheSameMetadataAndBody() throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let body = "# Body\n\nSome text.\n"

    try FrontmatterDocument(metadata: Self.metadata, content: body).save(to: file)

    let read = try Self.readBack(file)
    #expect(read.metadata == Self.metadata)
    #expect(read.body == body)
  }

  @Test func aBodyWithFenceLinesReadsBackUnchanged() throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }

    try FrontmatterDocument(metadata: Self.metadata, content: Self.bodyWithFences).save(to: file)

    let read = try Self.readBack(file)
    #expect(read.metadata == Self.metadata)
    #expect(read.body == Self.bodyWithFences)
  }

  @Test func aDocumentWithNoMetadataSavesItsBodyAlone() throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let body = "# Only a body\n"

    try FrontmatterDocument<Metadata>(metadata: nil, content: body).save(to: file)

    #expect(try String(contentsOf: file, encoding: .utf8) == body)
  }

  @Test func aBodyThatLooksLikeFrontmatterWithNoMetadataReadsBackUnchanged() throws {
    let body = "---\ntitle: not metadata\n---\nlast line\n"
    let document = FrontmatterDocument<Metadata>(metadata: nil, content: body)

    let split = FrontmatterDocument.split(text: try document.rendered())

    #expect(split.body == body)
  }

  @Test func aSaveLeavesNoTemporaryFileInTheFolder() throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }

    try FrontmatterDocument(metadata: Self.metadata, content: "body\n").save(to: file)

    #expect(try Self.names(in: folder) == [Self.fileName])
  }

  @Test func aNewFileGetsTheModeOfANewFile() throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }

    try FrontmatterDocument(metadata: Self.metadata, content: "body\n").save(to: file)

    #expect(try Self.mode(of: file) == Self.newFileMode)
  }

  @Test func aSaveOverAnOldFileReplacesItsTextAndKeepsItsMode() throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data(Self.oldText.utf8).write(to: file)
    try FileManager.default.setAttributes(
      [.posixPermissions: Self.ownerOnlyMode], ofItemAtPath: file.path)
    let body = "new body\n"

    try FrontmatterDocument(metadata: Self.metadata, content: body).save(to: file)

    let read = try Self.readBack(file)
    #expect(read.metadata == Self.metadata)
    #expect(read.body == body)
    #expect(try Self.mode(of: file) == Self.ownerOnlyMode)
  }

  @Test func aSaveThroughASymbolicLinkWritesTheTargetAndKeepsTheLink() throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data(Self.oldText.utf8).write(to: file)
    let link = folder.appendingPathComponent(Self.linkName)
    try FileManager.default.createSymbolicLink(
      atPath: link.path, withDestinationPath: Self.fileName)
    let body = "new body\n"

    try FrontmatterDocument(metadata: Self.metadata, content: body).save(to: link)

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == Self.fileName)
    let read = try Self.readBack(file)
    #expect(read.metadata == Self.metadata)
    #expect(read.body == body)
  }

  @Test func aFailedWriteLeavesTheOldFileWholeAndNoTemporaryFile() throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data(Self.oldText.utf8).write(to: file)
    let document = FrontmatterDocument(metadata: Self.metadata, content: "new body\n")
    let bytes = Data(try document.rendered().utf8)

    #expect(
      throws: FrontmatterDocumentSaveError.shortWrite(
        written: bytes.count / HalfWriteCalls.shortWriteDivisor, expected: bytes.count)
    ) {
      try document.save(to: file, calls: HalfWriteCalls.calls)
    }

    #expect(try String(contentsOf: file, encoding: .utf8) == Self.oldText)
    #expect(try Self.names(in: folder) == [Self.fileName])
  }

  @Test func aFailedEncodeThrowsAndLeavesTheOldFileWhole() throws {
    let (folder, file) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data(Self.oldText.utf8).write(to: file)
    let document = FrontmatterDocument(metadata: UnencodableMetadata(), content: "new body\n")

    #expect(
      throws: FrontmatterDocumentSaveError.encodingFailed(
        description: String(describing: UnencodableMetadata.failure))
    ) {
      try document.save(to: file)
    }

    #expect(try String(contentsOf: file, encoding: .utf8) == Self.oldText)
    #expect(try Self.names(in: folder) == [Self.fileName])
  }

  @Test func aSaveIntoAMissingFolderThrows() throws {
    let (folder, _) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("missing").appendingPathComponent(Self.fileName)

    #expect(throws: FrontmatterDocumentSaveError.temporaryFileFailed(errno: ENOENT)) {
      try FrontmatterDocument(metadata: Self.metadata, content: "body\n").save(to: file)
    }
  }
}
