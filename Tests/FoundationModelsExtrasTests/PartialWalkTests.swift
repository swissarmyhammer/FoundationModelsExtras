import Foundation
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for the include walk of `StenciledDotfolderStack`: an
/// `{% include %}` searches the partial locations of the folder of the
/// document, then of each ancestor folder, and last of the layer root. The
/// most specific folder wins. Layer precedence applies only between copies
/// in the same folder.
struct PartialWalkTests {
  typealias Fixture = DotfolderStackTests.Fixture

  /// A body that includes the `sah-x` partial with the leading location, as
  /// the swissarmyhammer corpus writes it.
  private static let includeBody = "{% include \"_partials/sah-x\" %}"

  /// The name of the partial file that each test writes, below a
  /// `_partials/` folder.
  private static let partialFileName = "sah-x.md"

  /// Fixed well-known values, so a render never depends on the state of the
  /// machine that runs the test.
  private static let fixtureWellKnownValues = WellKnownValues(
    workingDirectory: "/fixture/cwd", date: "2020-01-01", hostname: "fixture-host")

  /// A stenciled stack over `base`, with fixed well-known values.
  private static func makeStenciled(over base: DotfolderStack) -> StenciledDotfolderStack {
    StenciledDotfolderStack(base: base, wellKnownValues: fixtureWellKnownValues)
  }

  /// The path of the `sah-x` partial in the `_partials/` folder of
  /// `folder`.
  ///
  /// - Parameter folder: A folder relative to a layer root. The empty path
  ///   is the layer root.
  /// - Returns: The relative path of the partial file.
  private static func partialPath(inFolder folder: String) -> String {
    let partials = "_partials/\(partialFileName)"
    return folder.isEmpty ? partials : "\(folder)/\(partials)"
  }

  /// The layer of a document of the defaults of `fixture`, which renders
  /// trusted.
  private static func defaultsLayer(of fixture: Fixture) -> DotfolderStack.Layer {
    DotfolderStack.Layer(source: .defaults, root: fixture.defaultsDirectory)
  }

  // MARK: - One root, skills and agents

  @Test func aSkillAndAnAgentBelowOneRootBothResolveThePartialOfTheRoot() {
    let fixture = Fixture()
    fixture.write("root copy", to: Self.partialPath(inFolder: ""), in: fixture.defaultsDirectory)
    fixture.write(Self.includeBody, to: "commit/SKILL.md", in: fixture.defaultsDirectory)
    fixture.write(Self.includeBody, to: "agents/committer.md", in: fixture.defaultsDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    #expect(stenciled.content("commit/SKILL.md") == "root copy")
    #expect(stenciled.content("agents/committer.md") == "root copy")
  }

  @Test func theSkillsPartialsWinForASkillBelowSkillsAndAnAgentGetsTheRootCopy() {
    let fixture = Fixture()
    fixture.write("root copy", to: Self.partialPath(inFolder: ""), in: fixture.defaultsDirectory)
    fixture.write("skills copy", to: Self.partialPath(inFolder: "skills"), in: fixture.defaultsDirectory)
    fixture.write(Self.includeBody, to: "skills/commit/SKILL.md", in: fixture.defaultsDirectory)
    fixture.write(Self.includeBody, to: "agents/committer.md", in: fixture.defaultsDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    #expect(stenciled.content("skills/commit/SKILL.md") == "skills copy")
    #expect(stenciled.content("agents/committer.md") == "root copy")
  }

  @Test func aPartialNextToASkillWinsForThatSkillOnly() {
    let fixture = Fixture()
    fixture.write("root copy", to: Self.partialPath(inFolder: ""), in: fixture.defaultsDirectory)
    fixture.write("commit copy", to: Self.partialPath(inFolder: "commit"), in: fixture.defaultsDirectory)
    fixture.write(Self.includeBody, to: "commit/SKILL.md", in: fixture.defaultsDirectory)
    fixture.write(Self.includeBody, to: "review/SKILL.md", in: fixture.defaultsDirectory)
    fixture.write(Self.includeBody, to: "agents/committer.md", in: fixture.defaultsDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    #expect(stenciled.content("commit/SKILL.md") == "commit copy")
    #expect(stenciled.content("review/SKILL.md") == "root copy")
    #expect(stenciled.content("agents/committer.md") == "root copy")
  }

  // MARK: - The order of the walk

  /// Each document path of the order test, with the copy that its walk
  /// finds first.
  private static let walkOrderCases: [(documentPath: String, expected: String)] = [
    (documentPath: "a/b/doc.md", expected: "a/b copy"),
    (documentPath: "a/doc.md", expected: "a copy"),
    (documentPath: "doc.md", expected: "root copy"),
  ]

  @Test(arguments: walkOrderCases)
  func theWalkSearchesTheMostSpecificFolderFirstAndTheLayerRootLast(
    documentPath: String, expected: String
  ) throws {
    let fixture = Fixture()
    fixture.write("a/b copy", to: Self.partialPath(inFolder: "a/b"), in: fixture.defaultsDirectory)
    fixture.write("a copy", to: Self.partialPath(inFolder: "a"), in: fixture.defaultsDirectory)
    fixture.write("root copy", to: Self.partialPath(inFolder: ""), in: fixture.defaultsDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    let rendered = try stenciled.render(
      Self.includeBody, at: documentPath, in: Self.defaultsLayer(of: fixture))

    #expect(rendered == expected)
  }

  @Test func theWalkSkipsALevelWithNoCopyAndContinuesUp() throws {
    let fixture = Fixture()
    try FileManager.default.createDirectory(
      at: fixture.defaultsDirectory.appendingPathComponent("a/b/_partials", isDirectory: true),
      withIntermediateDirectories: true)
    fixture.write("a copy", to: Self.partialPath(inFolder: "a"), in: fixture.defaultsDirectory)
    fixture.write("root copy", to: Self.partialPath(inFolder: ""), in: fixture.defaultsDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    let rendered = try stenciled.render(
      Self.includeBody, at: "a/b/c/doc.md", in: Self.defaultsLayer(of: fixture))

    #expect(rendered == "a copy")
  }

  /// A body that includes three partials, `x`, `y` and `z`, each of which
  /// only one folder of the walk holds.
  private static let threePartialsBody =
    "{% include \"_partials/x\" %} {% include \"_partials/y\" %} {% include \"_partials/z\" %}"

  @Test func oneDocumentGetsDifferentPartialsFromDifferentLevels() throws {
    let fixture = Fixture()
    fixture.write("x of a/b", to: "a/b/_partials/x.md", in: fixture.defaultsDirectory)
    fixture.write("y of a", to: "a/_partials/y.md", in: fixture.defaultsDirectory)
    fixture.write("z of the root", to: "_partials/z.md", in: fixture.defaultsDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    let rendered = try stenciled.render(
      Self.threePartialsBody, at: "a/b/doc.md", in: Self.defaultsLayer(of: fixture))

    #expect(rendered == "x of a/b y of a z of the root")
  }

  /// Each document path of the deep walk test, with the copy that its walk
  /// finds first. Only `a/b/c/d/`, `a/` and the layer root hold a copy.
  private static let deepWalkCases: [(documentPath: String, expected: String)] = [
    (documentPath: "a/b/c/d/e/f/doc.md", expected: "a/b/c/d copy"),
    (documentPath: "a/b/c/d/doc.md", expected: "a/b/c/d copy"),
    (documentPath: "a/b/c/doc.md", expected: "a copy"),
    (documentPath: "doc.md", expected: "root copy"),
  ]

  @Test(arguments: deepWalkCases)
  func aWalkThroughSixLevelsFindsTheNearestCopy(documentPath: String, expected: String) throws {
    let fixture = Fixture()
    fixture.write("a/b/c/d copy", to: Self.partialPath(inFolder: "a/b/c/d"), in: fixture.defaultsDirectory)
    fixture.write("a copy", to: Self.partialPath(inFolder: "a"), in: fixture.defaultsDirectory)
    fixture.write("root copy", to: Self.partialPath(inFolder: ""), in: fixture.defaultsDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    let rendered = try stenciled.render(
      Self.includeBody, at: documentPath, in: Self.defaultsLayer(of: fixture))

    #expect(rendered == expected)
  }

  // MARK: - The walk and the layers

  /// Each document path of the deep walk test across layers, with the copy
  /// that its walk finds first. The defaults layer holds a copy in
  /// `a/b/c/d/e/`. The project layer, which is higher, holds a copy in
  /// `a/b/` and at its root.
  private static let deepLayerWalkCases: [(documentPath: String, expected: String)] = [
    (documentPath: "a/b/c/d/e/f/doc.md", expected: "defaults a/b/c/d/e copy"),
    (documentPath: "a/b/c/d/e/doc.md", expected: "defaults a/b/c/d/e copy"),
    (documentPath: "a/b/c/d/doc.md", expected: "project a/b copy"),
    (documentPath: "a/doc.md", expected: "project root copy"),
  ]

  @Test(arguments: deepLayerWalkCases)
  func aMoreSpecificFolderOfALowerLayerWinsAcrossSixLevels(documentPath: String, expected: String) throws {
    let fixture = Fixture()
    fixture.write(
      "defaults a/b/c/d/e copy", to: Self.partialPath(inFolder: "a/b/c/d/e"), in: fixture.defaultsDirectory)
    fixture.write("project a/b copy", to: Self.partialPath(inFolder: "a/b"), in: fixture.projectDirectory)
    fixture.write("project root copy", to: Self.partialPath(inFolder: ""), in: fixture.projectDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    let rendered = try stenciled.render(
      Self.includeBody, at: documentPath, in: Self.defaultsLayer(of: fixture))

    #expect(rendered == expected)
  }

  @Test func aMoreSpecificFolderOfALowerLayerWinsOverALessSpecificFolderOfAHigherLayer() {
    let fixture = Fixture()
    fixture.write(
      "defaults commit copy", to: Self.partialPath(inFolder: "commit"), in: fixture.defaultsDirectory)
    fixture.write("project root copy", to: Self.partialPath(inFolder: ""), in: fixture.projectDirectory)
    fixture.write(Self.includeBody, to: "commit/SKILL.md", in: fixture.defaultsDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    #expect(stenciled.content("commit/SKILL.md") == "defaults commit copy")
  }

  @Test func inOneFolderTheHighestLayerWins() {
    let fixture = Fixture()
    fixture.write("defaults copy", to: Self.partialPath(inFolder: "commit"), in: fixture.defaultsDirectory)
    fixture.write("user copy", to: Self.partialPath(inFolder: "commit"), in: fixture.userDirectory)
    fixture.write(Self.includeBody, to: "commit/SKILL.md", in: fixture.defaultsDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    #expect(stenciled.content("commit/SKILL.md") == "user copy")
  }

  // MARK: - The bounds of the walk

  @Test(arguments: ["a/doc.md", "../doc.md", "../../doc.md", "/doc.md"])
  func theWalkNeverGoesAboveTheLayerRoot(documentPath: String) {
    let fixture = Fixture()
    let layerRoot = fixture.root.appendingPathComponent("layer/inner", isDirectory: true)
    fixture.write("outside copy", to: Self.partialPath(inFolder: ""), in: fixture.root)
    fixture.write("outside copy", to: Self.partialPath(inFolder: "layer"), in: fixture.root)
    fixture.write("unrelated", to: "keep.md", in: layerRoot)
    let layer = DotfolderStack.Layer(source: .defaults, root: layerRoot)
    let stenciled = Self.makeStenciled(over: DotfolderStack(layers: [layer]))

    #expect(throws: TemplateEngineError.self) {
      try stenciled.render(Self.includeBody, at: documentPath, in: layer)
    }
  }

  @Test func renderInKeepsSearchingTheLayerRootOnly() throws {
    let fixture = Fixture()
    fixture.write("root copy", to: Self.partialPath(inFolder: ""), in: fixture.defaultsDirectory)
    fixture.write("commit copy", to: Self.partialPath(inFolder: "commit"), in: fixture.defaultsDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    let rendered = try stenciled.render(Self.includeBody, in: Self.defaultsLayer(of: fixture))

    #expect(rendered == "root copy")
  }

  // MARK: - The diagnostic

  @Test func theDiagnosticListsEachSearchedFolderInSearchOrder() throws {
    let fixture = Fixture()
    let lowRoot = fixture.root.appendingPathComponent("low", isDirectory: true)
    let highRoot = fixture.root.appendingPathComponent("high", isDirectory: true)
    let lowLayer = DotfolderStack.Layer(source: .defaults, root: lowRoot)
    let highLayer = DotfolderStack.Layer(source: .user, root: highRoot)
    let stenciled = Self.makeStenciled(over: DotfolderStack(layers: [lowLayer, highLayer]))
    let searched = [
      highRoot.appendingPathComponent("a/_partials").path,
      lowRoot.appendingPathComponent("a/_partials").path,
      highRoot.appendingPathComponent("_partials").path,
      lowRoot.appendingPathComponent("_partials").path,
    ]

    let error = try #require(throws: TemplateEngineError.self) {
      try stenciled.render(Self.includeBody, at: "a/doc.md", in: lowLayer)
    }

    #expect(
      error.description.contains(
        "partial \"_partials/sah-x\" not found; searched: \(searched.joined(separator: ", "))"))
  }
}
