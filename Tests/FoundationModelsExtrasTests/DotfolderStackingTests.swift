import Foundation
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for the `DotfolderStacking` interface as `DotfolderStack`
/// implements it: the generic `Located<Item>` result, `item(at:)`,
/// `items(in:named:)`, the byte lookups (`data`, the ranged `data`, `size`,
/// `exists`), and the symbolic-link confinement that each lookup applies.
/// Every test builds its own throwaway three-layer tree through
/// `DotfolderStackTests.Fixture`, so nothing touches the real home directory.
@Suite struct DotfolderStackingTests {
  typealias Fixture = DotfolderStackTests.Fixture

  /// Bytes that are not valid UTF-8: `0xFF` and `0xFE` never occur in a
  /// UTF-8 sequence.
  private static let binaryBytes = Data([0xFF, 0xFE, 0x00, 0x01, 0x02, 0x03])

  /// A range that lies inside `binaryBytes`.
  private static let innerRange = 2..<5

  /// A range that starts inside `binaryBytes` and ends past its end.
  private static let rangePastTheEnd = 4..<100

  /// The text of the winning copy of `relativePath`, read through the
  /// interface and not through the concrete type. It compiles only when
  /// `DotfolderStack` conforms to `DotfolderStacking` with `Item == String`.
  private static func winningText<Stack: DotfolderStacking>(
    of relativePath: String, in stack: Stack
  ) -> String? where Stack.Item == String {
    stack.item(at: relativePath)?.value
  }

  @Test func dotfolderStackConformsToDotfolderStackingWithStringItems() {
    let fixture = Fixture()
    fixture.write("project", to: "config.yaml", in: fixture.projectDirectory)
    let stack = fixture.makeStack()

    #expect(Self.winningText(of: "config.yaml", in: stack) == "project")
  }

  @Test func itemAtGivesTheHigherCopyAndNamesItsLayer() {
    let fixture = Fixture()
    fixture.write("defaults skill", to: "review/SKILL.md", in: fixture.defaultsDirectory)
    fixture.write("user skill", to: "review/SKILL.md", in: fixture.userDirectory)
    let stack = fixture.makeStack()

    let item = stack.item(at: "review/SKILL.md")

    #expect(item?.value == "user skill")
    #expect(item?.layer.source == .user)
    #expect(item?.url == fixture.userDirectory.appendingPathComponent("review/SKILL.md"))
  }

  @Test func itemAtGivesNilWhenNoLayerHoldsThePath() {
    let fixture = Fixture()
    let stack = fixture.makeStack()

    #expect(stack.item(at: "review/SKILL.md") == nil)
  }

  @Test func itemsInGivesOneEntryForEachChildDirectoryThatHoldsTheNamedFile() {
    let fixture = Fixture()
    fixture.write("review skill", to: "review/SKILL.md", in: fixture.defaultsDirectory)
    fixture.write("commit skill", to: "commit/SKILL.md", in: fixture.projectDirectory)
    fixture.write("no skill here", to: "scratch/notes.md", in: fixture.userDirectory)
    let stack = fixture.makeStack()

    let items = stack.items(in: nil, named: "SKILL.md")

    #expect(Set(items.keys) == ["review", "commit"])
    #expect(items["review"]?.value == "review skill")
    #expect(items["review"]?.layer.source == .defaults)
    #expect(items["commit"]?.value == "commit skill")
    #expect(items["commit"]?.layer.source == .project)
  }

  @Test func itemsInASubdirectoryGivesTheHighestCopyOfEachChildsFile() {
    let fixture = Fixture()
    fixture.write("defaults skill", to: "skills/review/SKILL.md", in: fixture.defaultsDirectory)
    fixture.write("user skill", to: "skills/review/SKILL.md", in: fixture.userDirectory)
    let stack = fixture.makeStack()

    let items = stack.items(in: "skills", named: "SKILL.md")

    #expect(items.count == 1)
    #expect(items["review"]?.value == "user skill")
    #expect(items["review"]?.layer.source == .user)
  }

  @Test func treeGivesTheTextOfEachWinningCopy() {
    let fixture = Fixture()
    fixture.writeReviewTree()
    let stack = fixture.makeStack()

    let view = stack.tree("review")

    #expect(view["SKILL.md"]?.value == "user skill")
    #expect(view["references/rules.md"]?.value == "defaults rules")
  }

  @Test func aFileThatIsNotValidUTF8GivesNilFromItemAtAndItsBytesFromData() {
    let fixture = Fixture()
    fixture.write(Self.binaryBytes, to: "assets/logo.bin", in: fixture.projectDirectory)
    let stack = fixture.makeStack()

    #expect(stack.item(at: "assets/logo.bin") == nil)
    #expect(stack.data("assets/logo.bin") == Self.binaryBytes)
  }

  @Test func dataGivesTheBytesOfTheHighestCopy() {
    let fixture = Fixture()
    fixture.write("defaults", to: "config.yaml", in: fixture.defaultsDirectory)
    fixture.write("project", to: "config.yaml", in: fixture.projectDirectory)
    let stack = fixture.makeStack()

    #expect(stack.data("config.yaml") == Data("project".utf8))
  }

  @Test func rangedDataGivesTheSameBytesAsTheFullReadForThatRange() {
    let fixture = Fixture()
    fixture.write(Self.binaryBytes, to: "assets/logo.bin", in: fixture.userDirectory)
    let stack = fixture.makeStack()

    let part = stack.data("assets/logo.bin", in: Self.innerRange)

    #expect(part == stack.data("assets/logo.bin")?.subdata(in: Self.innerRange))
    #expect(part == Self.binaryBytes.subdata(in: Self.innerRange))
  }

  @Test func rangedDataStopsAtTheEndOfTheFile() {
    let fixture = Fixture()
    fixture.write(Self.binaryBytes, to: "assets/logo.bin", in: fixture.userDirectory)
    let stack = fixture.makeStack()

    let tail = stack.data("assets/logo.bin", in: Self.rangePastTheEnd)

    #expect(tail == Self.binaryBytes.dropFirst(Self.rangePastTheEnd.lowerBound))
  }

  @Test func sizeOfGivesTheSizeOfTheHighestCopy() {
    let fixture = Fixture()
    fixture.write("defaults", to: "config.yaml", in: fixture.defaultsDirectory)
    fixture.write("project wins", to: "config.yaml", in: fixture.projectDirectory)
    let stack = fixture.makeStack()

    #expect(stack.size(of: "config.yaml") == "project wins".utf8.count)
  }

  @Test func existsIsTrueWhenAnyLayerHoldsThePath() {
    let fixture = Fixture()
    fixture.write("defaults", to: "config.yaml", in: fixture.defaultsDirectory)
    let stack = fixture.makeStack()

    #expect(stack.exists("config.yaml"))
  }

  @Test func byteLookupsGiveNothingWhenNoLayerHoldsThePath() {
    let fixture = Fixture()
    let stack = fixture.makeStack()

    #expect(stack.data("config.yaml") == nil)
    #expect(stack.data("config.yaml", in: 0..<1) == nil)
    #expect(stack.size(of: "config.yaml") == nil)
    #expect(!stack.exists("config.yaml"))
  }

  @Test func byteLookupsRejectUnsafePaths() {
    let fixture = Fixture()
    fixture.write("secret", to: "secret.txt", in: fixture.root)
    let stack = fixture.makeStack()

    for path in ["", "/etc/passwd", "../secret.txt"] {
      #expect(stack.item(at: path) == nil, "item(at: \(path))")
      #expect(stack.data(path) == nil, "data(\(path))")
      #expect(stack.data(path, in: 0..<1) == nil, "data(\(path), in:)")
      #expect(stack.size(of: path) == nil, "size(of: \(path))")
      #expect(!stack.exists(path), "exists(\(path))")
      #expect(stack.items(in: path, named: "secret.txt").isEmpty, "items(in: \(path))")
    }
  }

  @Test func aSymbolicLinkToAFileOutsideTheLayerRootGivesNoResult() {
    let fixture = Fixture()
    let secretURL = fixture.root.appendingPathComponent("outside/secret.txt")
    fixture.write("secret", to: "outside/secret.txt", in: fixture.root)
    fixture.link("leak.txt", in: fixture.projectDirectory, to: secretURL)
    let stack = fixture.makeStack()

    #expect(stack.item(at: "leak.txt") == nil)
    #expect(stack.data("leak.txt") == nil)
    #expect(stack.data("leak.txt", in: 0..<1) == nil)
    #expect(stack.size(of: "leak.txt") == nil)
    #expect(!stack.exists("leak.txt"))
    #expect(stack.nearest("leak.txt") == nil)
    #expect(stack.content("leak.txt") == nil)
    #expect(stack.locate("leak.txt").isEmpty)
    #expect(stack.tree()["leak.txt"] == nil)
  }

  @Test func aSymbolicLinkToADirectoryOutsideTheLayerRootIsNotInTheView() {
    let fixture = Fixture()
    let outsideURL = fixture.root.appendingPathComponent("outside", isDirectory: true)
    fixture.write("secret", to: "outside/secret.txt", in: fixture.root)
    fixture.link("escaped", in: fixture.projectDirectory, to: outsideURL)
    let stack = fixture.makeStack()

    #expect(stack.tree()["escaped/secret.txt"] == nil)
    #expect(stack.childDirectories()["escaped"] == nil)
    #expect(stack.layerDirectories("escaped").isEmpty)
    #expect(stack.items(in: nil, named: "secret.txt").isEmpty)
    #expect(stack.item(at: "escaped/secret.txt") == nil)
    #expect(stack.enumerate("escaped", suffix: ".txt").isEmpty)
  }

  @Test func aSymbolicLinkThatStaysInsideTheLayerRootIsFollowed() {
    let fixture = Fixture()
    fixture.write("real", to: "real.txt", in: fixture.projectDirectory)
    fixture.link(
      "alias.txt", in: fixture.projectDirectory,
      to: fixture.projectDirectory.appendingPathComponent("real.txt"))
    let stack = fixture.makeStack()

    #expect(stack.item(at: "alias.txt")?.value == "real")
    #expect(stack.exists("alias.txt"))
  }
}
