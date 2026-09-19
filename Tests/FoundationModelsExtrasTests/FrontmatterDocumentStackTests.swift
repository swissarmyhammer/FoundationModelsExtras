import Foundation
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `FrontmatterDocumentStack`: the same lookups as the
/// stack below it, with each text split into a `(metadata, content)` pair.
/// The tests cover the split over the plain stack and over the stenciled
/// stack, the files with no frontmatter, the decode failure, the default
/// `YAMLValue` decoder, and the lookups that pass through to the base.
/// Every test builds its own throwaway three-layer tree through
/// `DotfolderStackTests.Fixture`, so nothing touches the real home
/// directory.
@Suite struct FrontmatterDocumentStackTests {
  typealias Fixture = DotfolderStackTests.Fixture

  /// The variables that each stenciled test gives to the stack.
  private static let variables = ["project": "acme"]

  /// A document with a frontmatter block and a body.
  private static let skillDocument = "---\nname: review\n---\n# Review\n"

  /// The text between the fences of `skillDocument`, as the split gives it.
  private static let skillFrontmatter = "name: review\n"

  /// The text after the closing fence of `skillDocument`.
  private static let skillContent = "# Review\n"

  /// A document that reads one consumer variable in a value of the
  /// frontmatter and in the body.
  private static let templatedDocument = "---\ntitle: {{ project }}\n---\nProject {{ project }}\n"

  /// A document with no frontmatter block.
  private static let plainDocument = "# No frontmatter\n"

  /// A document whose opening fence has no closing fence.
  private static let unterminatedDocument = "---\nname: review\n# Still the body\n"

  /// A document whose frontmatter is not valid YAML.
  private static let malformedDocument = "---\nname: [unclosed\n---\n# Body\n"

  /// A range that lies inside the first bytes of a fixture file.
  private static let leadingBytes = 0..<4

  /// A stack over `base` whose metadata is the raw frontmatter text, and
  /// that records its diagnostics in `log`.
  private static func makeRawStack<Base: DotfolderStacking>(
    over base: Base, log: DiagnosticLog = DiagnosticLog()
  ) -> FrontmatterDocumentStack<Base, String> where Base.Item == String {
    FrontmatterDocumentStack(base: base, decode: { $0 }, onDiagnostic: { log.record($0) })
  }

  /// A stenciled stack over the fixture's plain stack, with `variables`.
  private static func makeStenciled(_ fixture: Fixture) -> StenciledDotfolderStack {
    StenciledDotfolderStack(base: fixture.makeStack(), variables: variables)
  }

  // MARK: - Over the plain stack

  @Test func itemAtGivesTheMetadataAndTheContentOfTheWinningCopy() {
    let fixture = Fixture()
    fixture.write(Self.skillDocument, to: "review/SKILL.md", in: fixture.userDirectory)
    let stack = fixture.makeStack()
    let documents = Self.makeRawStack(over: stack)

    let item = documents.item(at: "review/SKILL.md")

    #expect(item?.value.metadata == Self.skillFrontmatter)
    #expect(item?.value.content == Self.skillContent)
    #expect(item?.url == stack.item(at: "review/SKILL.md")?.url)
    #expect(item?.layer.source == .user)
  }

  @Test func theHigherLayerWins() {
    let fixture = Fixture()
    fixture.write(
      "---\nname: defaults\n---\ndefaults\n", to: "review/SKILL.md", in: fixture.defaultsDirectory)
    fixture.write(
      "---\nname: project\n---\nproject\n", to: "review/SKILL.md", in: fixture.projectDirectory)
    let documents = Self.makeRawStack(over: fixture.makeStack())

    let item = documents.item(at: "review/SKILL.md")

    #expect(item?.value.metadata == "name: project\n")
    #expect(item?.value.content == "project\n")
    #expect(item?.layer.source == .project)
  }

  @Test func itemAtGivesNilWhenNoLayerHoldsThePath() {
    let fixture = Fixture()
    let documents = Self.makeRawStack(over: fixture.makeStack())

    #expect(documents.item(at: "review/SKILL.md") == nil)
  }

  @Test func contentIsTheTextAfterTheFenceByteForByte() {
    let fixture = Fixture()
    let text = "---\r\nname: review\r\n---\r\n# Review\r\n\r\n  indented\r\n"
    fixture.write(text, to: "review/SKILL.md", in: fixture.projectDirectory)
    let documents = Self.makeRawStack(over: fixture.makeStack())

    let document = documents.item(at: "review/SKILL.md")?.value

    #expect(document?.metadata == "name: review\r\n")
    #expect(document?.content == "# Review\r\n\r\n  indented\r\n")
  }

  @Test func aTemplateInTheFrontmatterIsNotRenderedOverThePlainStack() {
    let fixture = Fixture()
    fixture.write(Self.templatedDocument, to: "review/SKILL.md", in: fixture.projectDirectory)
    let documents = Self.makeRawStack(over: fixture.makeStack())

    let document = documents.item(at: "review/SKILL.md")?.value

    #expect(document?.metadata == "title: {{ project }}\n")
    #expect(document?.content == "Project {{ project }}\n")
  }

  // MARK: - Over the stenciled stack

  @Test func aTemplateInTheBodyAndInAFrontmatterValueAreBothRenderedOverTheStenciledStack() {
    let fixture = Fixture()
    fixture.write(Self.templatedDocument, to: "review/SKILL.md", in: fixture.projectDirectory)
    let documents = Self.makeRawStack(over: Self.makeStenciled(fixture))

    let document = documents.item(at: "review/SKILL.md")?.value

    #expect(document?.metadata == "title: acme\n")
    #expect(document?.content == "Project acme\n")
  }

  @Test func aRenderFailureBelowLeavesTheDocumentOut() {
    let fixture = Fixture()
    fixture.write(
      "---\nname: x\n---\n{% now \"yyyy\" %}", to: "review/SKILL.md", in: fixture.projectDirectory)
    let documents = Self.makeRawStack(over: Self.makeStenciled(fixture))

    #expect(documents.item(at: "review/SKILL.md") == nil)
  }

  // MARK: - No frontmatter

  @Test func aFileWithNoFrontmatterGivesNilMetadataAndTheFullText() {
    let fixture = Fixture()
    fixture.write(Self.plainDocument, to: "review/SKILL.md", in: fixture.projectDirectory)
    let log = DiagnosticLog()
    let documents = Self.makeRawStack(over: fixture.makeStack(), log: log)

    let document = documents.item(at: "review/SKILL.md")?.value

    #expect(document?.metadata == nil)
    #expect(document?.content == Self.plainDocument)
    #expect(log.diagnostics.isEmpty)
  }

  @Test func aFileWithAnUnterminatedFenceGivesNilMetadataAndTheFullText() {
    let fixture = Fixture()
    fixture.write(Self.unterminatedDocument, to: "review/SKILL.md", in: fixture.projectDirectory)
    let log = DiagnosticLog()
    let documents = Self.makeRawStack(over: fixture.makeStack(), log: log)

    let document = documents.item(at: "review/SKILL.md")?.value

    #expect(document?.metadata == nil)
    #expect(document?.content == Self.unterminatedDocument)
    #expect(log.diagnostics.isEmpty)
  }

  // MARK: - Decode failure

  @Test func aDecoderThatGivesNilGivesOneDiagnosticAndKeepsTheContent() {
    let fixture = Fixture()
    fixture.write(Self.skillDocument, to: "review/SKILL.md", in: fixture.userDirectory)
    let stack = fixture.makeStack()
    let log = DiagnosticLog()
    let documents = FrontmatterDocumentStack<DotfolderStack, String>(
      base: stack, decode: { _ in nil }, onDiagnostic: { log.record($0) })

    let document = documents.item(at: "review/SKILL.md")?.value

    #expect(document?.metadata == nil)
    #expect(document?.content == Self.skillContent)
    #expect(log.diagnostics.count == 1)
    #expect(log.diagnostics.first?.url == stack.item(at: "review/SKILL.md")?.url)
    #expect(log.diagnostics.first?.layer.source == .user)
  }

  @Test func theDecoderReceivesTheRawFrontmatterText() {
    let fixture = Fixture()
    fixture.write(Self.skillDocument, to: "review/SKILL.md", in: fixture.userDirectory)
    let documents = FrontmatterDocumentStack<DotfolderStack, Int>(
      base: fixture.makeStack(), decode: { $0.count })

    #expect(documents.item(at: "review/SKILL.md")?.value.metadata == Self.skillFrontmatter.count)
  }

  // MARK: - The default YAML decoder

  @Test func theDefaultDecoderGivesAYAMLValue() {
    let fixture = Fixture()
    fixture.write(Self.skillDocument, to: "review/SKILL.md", in: fixture.userDirectory)
    let documents = FrontmatterDocumentStack(base: fixture.makeStack())

    let document = documents.item(at: "review/SKILL.md")?.value

    #expect(document?.metadata == .dictionary(["name": .string("review")]))
    #expect(document?.content == Self.skillContent)
  }

  @Test func theDefaultDecoderGivesNilAndOneDiagnosticForMalformedYAML() {
    let fixture = Fixture()
    fixture.write(Self.malformedDocument, to: "review/SKILL.md", in: fixture.projectDirectory)
    let log = DiagnosticLog()
    let documents = FrontmatterDocumentStack(
      base: fixture.makeStack(), onDiagnostic: { log.record($0) })

    let document = documents.item(at: "review/SKILL.md")?.value

    #expect(document?.metadata == nil)
    #expect(document?.content == "# Body\n")
    #expect(log.diagnostics.count == 1)
    #expect(log.diagnostics.first?.layer.source == .project)
  }

  // MARK: - Each text lookup is split

  @Test func itemsInGivesOneDocumentForEachChildDirectoryThatHoldsTheFile() {
    let fixture = Fixture()
    fixture.write(
      "---\nname: review\n---\nreview\n", to: "review/SKILL.md", in: fixture.defaultsDirectory)
    fixture.write(
      "---\nname: commit\n---\ncommit\n", to: "commit/SKILL.md", in: fixture.projectDirectory)
    fixture.write("notes", to: "scratch/NOTES.md", in: fixture.userDirectory)
    let documents = Self.makeRawStack(over: fixture.makeStack())

    let items = documents.items(in: nil, named: "SKILL.md")

    #expect(Set(items.keys) == ["review", "commit"])
    #expect(items["review"]?.value.metadata == "name: review\n")
    #expect(items["review"]?.value.content == "review\n")
    #expect(items["commit"]?.value.metadata == "name: commit\n")
    #expect(items["commit"]?.layer.source == .project)
  }

  @Test func treeGivesEachWinningCopySplit() {
    let fixture = Fixture()
    fixture.write(
      "---\nname: defaults\n---\ndefaults\n", to: "review/SKILL.md", in: fixture.defaultsDirectory)
    fixture.write("---\nname: user\n---\nuser\n", to: "review/SKILL.md", in: fixture.userDirectory)
    fixture.write("rules", to: "review/references/rules.md", in: fixture.defaultsDirectory)
    let documents = Self.makeRawStack(over: fixture.makeStack())

    let view = documents.tree("review")

    #expect(view["SKILL.md"]?.value.metadata == "name: user\n")
    #expect(view["SKILL.md"]?.value.content == "user\n")
    #expect(view["SKILL.md"]?.layer.source == .user)
    #expect(view["references/rules.md"]?.value.metadata == nil)
    #expect(view["references/rules.md"]?.value.content == "rules")
  }

  // MARK: - The same files as the base stack

  @Test func layersAreTheLayersOfTheBaseStack() {
    let fixture = Fixture()
    let stack = fixture.makeStack()
    let documents = Self.makeRawStack(over: stack)

    #expect(documents.layers.map(\.source) == stack.layers.map(\.source))
    #expect(documents.layers.map(\.root) == stack.layers.map(\.root))
  }

  @Test func eachLookupGivesTheSameFilesAsTheBaseStack() {
    let fixture = Fixture()
    fixture.writeReviewTree()
    let stack = fixture.makeStack()
    let documents = Self.makeRawStack(over: stack)

    #expect(documents.item(at: "review/SKILL.md")?.url == stack.item(at: "review/SKILL.md")?.url)
    #expect(
      documents.items(in: nil, named: "SKILL.md").mapValues(\.url)
        == stack.items(in: nil, named: "SKILL.md").mapValues(\.url))
    #expect(documents.tree("review").mapValues(\.url) == stack.tree("review").mapValues(\.url))
    #expect(documents.urls("review").mapValues(\.value) == stack.urls("review").mapValues(\.value))
    #expect(
      documents.childDirectories(of: "review").mapValues { $0.map(\.source) }
        == stack.childDirectories(of: "review").mapValues { $0.map(\.source) })
    #expect(
      documents.layerDirectories("review").map(\.source)
        == stack.layerDirectories("review").map(\.source))
    #expect(documents.data("review/SKILL.md") == stack.data("review/SKILL.md"))
    #expect(
      documents.data("review/SKILL.md", in: Self.leadingBytes)
        == stack.data("review/SKILL.md", in: Self.leadingBytes))
    #expect(documents.size(of: "review/SKILL.md") == stack.size(of: "review/SKILL.md"))
    #expect(documents.exists("review/SKILL.md") == stack.exists("review/SKILL.md"))
    #expect(documents.exists("review/missing.md") == stack.exists("review/missing.md"))
  }

  @Test func urlsGivesAFileThatIsNotTextAsTheBaseStackGives() {
    let fixture = Fixture()
    fixture.write(Fixture.binaryBytes, to: "assets/logo.png", in: fixture.projectDirectory)
    let stack = fixture.makeStack()
    let documents = Self.makeRawStack(over: stack)

    #expect(
      documents.urls()["assets/logo.png"]?.value
        == fixture.projectDirectory.appendingPathComponent("assets/logo.png"))
    #expect(documents.tree()["assets/logo.png"] == nil)
  }

  @Test func theByteLookupsGiveTheBytesOfTheWholeFileNotTheContent() {
    let fixture = Fixture()
    fixture.write(Self.skillDocument, to: "review/SKILL.md", in: fixture.projectDirectory)
    let documents = Self.makeRawStack(over: fixture.makeStack())

    #expect(documents.data("review/SKILL.md") == Data(Self.skillDocument.utf8))
    #expect(documents.size(of: "review/SKILL.md") == Self.skillDocument.utf8.count)
  }

  @Test func constructingADocumentStackPerformsNoFileIO() {
    let fixture = Fixture()
    let missingDefaultsDirectory = fixture.root.appendingPathComponent(
      "brand-new", isDirectory: true)

    _ = Self.makeRawStack(over: fixture.makeStack(defaultsDirectory: missingDefaultsDirectory))

    #expect(!FileManager.default.fileExists(atPath: missingDefaultsDirectory.path))
  }
}
