import Foundation
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `StenciledDotfolderStack`: the same lookups as the
/// plain stack, with each text rendered through Stencil first. The tests
/// cover the variables, the well-known values, the partial locations, the
/// scope of the partials, the trust of each layer, and the diagnostic hook.
/// Every test builds its own throwaway three-layer tree through
/// `DotfolderStackTests.Fixture`, so nothing touches the real home
/// directory.
@Suite struct StenciledDotfolderStackTests {
  typealias Fixture = DotfolderStackTests.Fixture

  /// The variables that each test gives to the stack.
  private static let variables = ["project": "acme"]

  /// A body that reads one consumer variable.
  private static let projectBody = "Project {{ project }}"

  /// A body that uses a tag that the untrusted path does not allow.
  private static let disallowedTagBody = "{% now \"yyyy\" %}"

  /// A body that uses a filter that the untrusted path does not allow.
  private static let disallowedFilterBody = "{{ project|uppercase }}"

  /// A body that includes the `header` partial.
  private static let includeHeaderBody = "{% include \"header\" %}"

  /// A range that lies inside the first bytes of a fixture file.
  private static let leadingBytes = 0..<4

  /// A stenciled stack over `base` that records its diagnostics in `log`.
  private static func makeStenciled(
    over base: DotfolderStack,
    partialLocations: [String] = ["_partials"],
    variables: [String: String] = variables,
    log: DiagnosticLog = DiagnosticLog()
  ) -> StenciledDotfolderStack {
    StenciledDotfolderStack(
      base: base,
      partialLocations: partialLocations,
      variables: variables,
      onDiagnostic: { log.record($0) }
    )
  }

  /// A marketplace layer rooted in `fixture`, placed below the local
  /// layers of the fixture's stack.
  private static func makeMarketplaceStack(_ fixture: Fixture) -> (
    stack: DotfolderStack, marketplaceDirectory: URL
  ) {
    let marketplaceDirectory = fixture.root.appendingPathComponent("marketplace", isDirectory: true)
    var stack = fixture.makeStack()
    stack.layers.insert(
      DotfolderStack.Layer(source: .marketplace, root: marketplaceDirectory), at: 0)
    return (stack, marketplaceDirectory)
  }

  // MARK: - Variables and well-known values

  @Test func contentGivesTheBodyRenderedWithAConsumerVariable() {
    let fixture = Fixture()
    fixture.write(Self.projectBody, to: "review/SKILL.md", in: fixture.projectDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    #expect(stenciled.content("review/SKILL.md") == "Project acme")
  }

  @Test func contentGivesTheSameTextAsThePlainStackWhenTheBodyHasNoTemplate() {
    let fixture = Fixture()
    fixture.write("plain text", to: "review/SKILL.md", in: fixture.userDirectory)
    let stack = fixture.makeStack()
    let stenciled = Self.makeStenciled(over: stack)

    #expect(stenciled.content("review/SKILL.md") == stack.content("review/SKILL.md"))
  }

  @Test func contentGivesNilWhenNoLayerHoldsThePath() {
    let fixture = Fixture()
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    #expect(stenciled.content("review/SKILL.md") == nil)
  }

  @Test func aWellKnownValueIsAvailableToTheBody() {
    let fixture = Fixture()
    fixture.write("{{ dotfolder_name }}", to: "review/SKILL.md", in: fixture.projectDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    #expect(stenciled.content("review/SKILL.md") == "testagent")
  }

  @Test func aConsumerVariableWinsOverAWellKnownValueOfTheSameName() {
    let fixture = Fixture()
    fixture.write("{{ dotfolder_name }}", to: "review/SKILL.md", in: fixture.projectDirectory)
    let stenciled = Self.makeStenciled(
      over: fixture.makeStack(), variables: ["dotfolder_name": "from-consumer"])

    #expect(stenciled.content("review/SKILL.md") == "from-consumer")
  }

  // MARK: - Each text lookup is rendered

  @Test func itemAtGivesTheRenderedTextWithTheUrlAndLayerOfThePlainStack() {
    let fixture = Fixture()
    fixture.write(Self.projectBody, to: "review/SKILL.md", in: fixture.userDirectory)
    let stack = fixture.makeStack()
    let stenciled = Self.makeStenciled(over: stack)

    let item = stenciled.item(at: "review/SKILL.md")

    #expect(item?.value == "Project acme")
    #expect(item?.url == stack.item(at: "review/SKILL.md")?.url)
    #expect(item?.layer.source == .user)
  }

  @Test func itemsInGivesEachChildsFileRendered() {
    let fixture = Fixture()
    fixture.write(
      "review {{ project }}", to: "skills/review/SKILL.md", in: fixture.defaultsDirectory)
    fixture.write(
      "commit {{ project }}", to: "skills/commit/SKILL.md", in: fixture.projectDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    let items = stenciled.items(in: "skills", named: "SKILL.md")

    #expect(Set(items.keys) == ["review", "commit"])
    #expect(items["review"]?.value == "review acme")
    #expect(items["commit"]?.value == "commit acme")
  }

  @Test func treeGivesEachWinningCopyRendered() {
    let fixture = Fixture()
    fixture.write("defaults {{ project }}", to: "review/SKILL.md", in: fixture.defaultsDirectory)
    fixture.write("user {{ project }}", to: "review/SKILL.md", in: fixture.userDirectory)
    fixture.write(
      "rules {{ project }}", to: "review/references/rules.md", in: fixture.defaultsDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    let view = stenciled.tree("review")

    #expect(view["SKILL.md"]?.value == "user acme")
    #expect(view["SKILL.md"]?.layer.source == .user)
    #expect(view["references/rules.md"]?.value == "rules acme")
  }

  // MARK: - Partial locations

  @Test func anIncludeResolvesFromTheDefaultPartialsLocation() {
    let fixture = Fixture()
    fixture.write("defaults header", to: "_partials/header.md", in: fixture.defaultsDirectory)
    fixture.write(Self.includeHeaderBody, to: "review/SKILL.md", in: fixture.projectDirectory)
    let stenciled = StenciledDotfolderStack(base: fixture.makeStack())

    #expect(stenciled.content("review/SKILL.md") == "defaults header")
  }

  @Test func anIncludeResolvesFromAPartialLocationAndTheHigherLayerWins() {
    let fixture = Fixture()
    fixture.write("defaults header", to: "snippets/header.md", in: fixture.defaultsDirectory)
    fixture.write("user header", to: "snippets/header.md", in: fixture.userDirectory)
    fixture.write(Self.includeHeaderBody, to: "review/SKILL.md", in: fixture.projectDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack(), partialLocations: ["snippets"])

    #expect(stenciled.content("review/SKILL.md") == "user header")
  }

  @Test func anIncludeSearchesEachPartialLocationAndTheHigherLayerWins() {
    let fixture = Fixture()
    fixture.write("defaults header", to: "_partials/header.md", in: fixture.defaultsDirectory)
    fixture.write("user header", to: "snippets/header.md", in: fixture.userDirectory)
    fixture.write(Self.includeHeaderBody, to: "review/SKILL.md", in: fixture.projectDirectory)
    let stenciled = Self.makeStenciled(
      over: fixture.makeStack(), partialLocations: ["_partials", "snippets"])

    #expect(stenciled.content("review/SKILL.md") == "user header")
  }

  @Test func anIncludeDoesNotResolveOutsideThePartialLocations() {
    let fixture = Fixture()
    fixture.write("defaults header", to: "_partials/header.md", in: fixture.defaultsDirectory)
    fixture.write(Self.includeHeaderBody, to: "review/SKILL.md", in: fixture.projectDirectory)
    let log = DiagnosticLog()
    let stenciled = Self.makeStenciled(
      over: fixture.makeStack(), partialLocations: ["snippets"], log: log)

    #expect(stenciled.content("review/SKILL.md") == nil)
    #expect(log.diagnostics.count == 1)
    #expect(log.diagnostics.first?.message.contains("header") == true)
  }

  // MARK: - Scope of the partials

  @Test func aMarketplaceDocumentIncludesAPartialOfItsOwnLayer() {
    let fixture = Fixture()
    let (stack, marketplaceDirectory) = Self.makeMarketplaceStack(fixture)
    fixture.write("market header", to: "_partials/header.md", in: marketplaceDirectory)
    fixture.write(Self.includeHeaderBody, to: "skills/x/SKILL.md", in: marketplaceDirectory)
    let stenciled = Self.makeStenciled(over: stack)

    #expect(stenciled.content("skills/x/SKILL.md") == "market header")
  }

  @Test func aLocalPartialWinsOverTheMarketplacePartialOfTheSameName() {
    let fixture = Fixture()
    let (stack, marketplaceDirectory) = Self.makeMarketplaceStack(fixture)
    fixture.write("market header", to: "_partials/header.md", in: marketplaceDirectory)
    fixture.write("user header", to: "_partials/header.md", in: fixture.userDirectory)
    fixture.write(Self.includeHeaderBody, to: "skills/x/SKILL.md", in: marketplaceDirectory)
    let stenciled = Self.makeStenciled(over: stack)

    #expect(stenciled.content("skills/x/SKILL.md") == "user header")
  }

  @Test func aLocalDocumentDoesNotSeeAPartialThatOnlyAMarketplaceHolds() {
    let fixture = Fixture()
    let (stack, marketplaceDirectory) = Self.makeMarketplaceStack(fixture)
    fixture.write("market header", to: "_partials/header.md", in: marketplaceDirectory)
    fixture.write(Self.includeHeaderBody, to: "review/SKILL.md", in: fixture.projectDirectory)
    let log = DiagnosticLog()
    let stenciled = Self.makeStenciled(over: stack, log: log)

    #expect(stenciled.content("review/SKILL.md") == nil)
    #expect(log.diagnostics.count == 1)
  }

  // MARK: - Trust

  @Test func aDefaultsDocumentRendersTrusted() {
    let fixture = Fixture()
    fixture.write(Self.disallowedFilterBody, to: "review/SKILL.md", in: fixture.defaultsDirectory)
    let log = DiagnosticLog()
    let stenciled = Self.makeStenciled(over: fixture.makeStack(), log: log)

    #expect(stenciled.content("review/SKILL.md") == "ACME")
    #expect(log.diagnostics.isEmpty)
  }

  @Test func anUntrustedDocumentWithADisallowedTagGivesNilAndOneDiagnostic() {
    let fixture = Fixture()
    fixture.write(Self.disallowedTagBody, to: "review/SKILL.md", in: fixture.projectDirectory)
    let log = DiagnosticLog()
    let stack = fixture.makeStack()
    let stenciled = Self.makeStenciled(over: stack, log: log)

    let content = stenciled.content("review/SKILL.md")

    #expect(content == nil)
    #expect(log.diagnostics.count == 1)
    #expect(log.diagnostics.first?.message.contains("now") == true)
    #expect(log.diagnostics.first?.url == stack.item(at: "review/SKILL.md")?.url)
    #expect(log.diagnostics.first?.layer.source == .project)
  }

  @Test func anUntrustedDocumentWithADisallowedFilterGivesNil() {
    let fixture = Fixture()
    fixture.write(Self.disallowedFilterBody, to: "review/SKILL.md", in: fixture.userDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    #expect(stenciled.content("review/SKILL.md") == nil)
  }

  @Test func anUntrustedDocumentIsSubjectToTheIncludeDepthLimit() {
    let fixture = Fixture()
    fixture.write("{% include \"loop\" %}", to: "_partials/loop.md", in: fixture.projectDirectory)
    fixture.write("{% include \"loop\" %}", to: "review/SKILL.md", in: fixture.projectDirectory)
    let log = DiagnosticLog()
    let stenciled = Self.makeStenciled(over: fixture.makeStack(), log: log)

    #expect(stenciled.content("review/SKILL.md") == nil)
    #expect(log.diagnostics.first?.message.contains("include depth") == true)
  }

  @Test func aRenderFailureInsideATreeLeavesThatEntryOutAndKeepsTheOthers() {
    let fixture = Fixture()
    fixture.write(Self.disallowedTagBody, to: "review/SKILL.md", in: fixture.projectDirectory)
    fixture.write(Self.projectBody, to: "review/NOTES.md", in: fixture.projectDirectory)
    let log = DiagnosticLog()
    let stenciled = Self.makeStenciled(over: fixture.makeStack(), log: log)

    let view = stenciled.tree("review")

    #expect(Set(view.keys) == ["NOTES.md"])
    #expect(view["NOTES.md"]?.value == "Project acme")
    #expect(log.diagnostics.count == 1)
  }

  // MARK: - The same files as the plain stack

  @Test func layersAreTheLayersOfThePlainStack() {
    let fixture = Fixture()
    let stack = fixture.makeStack()
    let stenciled = Self.makeStenciled(over: stack)

    #expect(stenciled.layers.map(\.source) == stack.layers.map(\.source))
    #expect(stenciled.layers.map(\.root) == stack.layers.map(\.root))
  }

  @Test func eachLookupGivesTheSameFilesAsThePlainStack() {
    let fixture = Fixture()
    fixture.writeReviewTree()
    let stack = fixture.makeStack()
    let stenciled = Self.makeStenciled(over: stack)

    #expect(stenciled.item(at: "review/SKILL.md")?.url == stack.item(at: "review/SKILL.md")?.url)
    #expect(
      stenciled.items(in: nil, named: "SKILL.md").mapValues(\.url)
        == stack.items(in: nil, named: "SKILL.md").mapValues(\.url))
    #expect(stenciled.tree("review").mapValues(\.url) == stack.tree("review").mapValues(\.url))
    #expect(
      stenciled.childDirectories(of: "review").mapValues { $0.map(\.source) }
        == stack.childDirectories(of: "review").mapValues { $0.map(\.source) })
    #expect(
      stenciled.layerDirectories("review").map(\.source)
        == stack.layerDirectories("review").map(\.source))
    #expect(stenciled.data("review/SKILL.md") == stack.data("review/SKILL.md"))
    #expect(
      stenciled.data("review/SKILL.md", in: Self.leadingBytes)
        == stack.data("review/SKILL.md", in: Self.leadingBytes))
    #expect(stenciled.size(of: "review/SKILL.md") == stack.size(of: "review/SKILL.md"))
    #expect(stenciled.exists("review/SKILL.md") == stack.exists("review/SKILL.md"))
    #expect(stenciled.exists("review/missing.md") == stack.exists("review/missing.md"))
  }

  @Test func theByteLookupsGiveTheBytesOfTheFileNotTheRenderedText() {
    let fixture = Fixture()
    fixture.write(Self.projectBody, to: "review/SKILL.md", in: fixture.projectDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    #expect(stenciled.data("review/SKILL.md") == Data(Self.projectBody.utf8))
    #expect(stenciled.size(of: "review/SKILL.md") == Self.projectBody.utf8.count)
  }

  @Test func constructingAStenciledStackPerformsNoFileIO() {
    let fixture = Fixture()
    let missingDefaultsDirectory = fixture.root.appendingPathComponent(
      "brand-new", isDirectory: true)

    _ = Self.makeStenciled(over: fixture.makeStack(defaultsDirectory: missingDefaultsDirectory))

    #expect(!FileManager.default.fileExists(atPath: missingDefaultsDirectory.path))
  }
}
