import Foundation
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `StenciledDotfolderStack.render(_:in:)`, the entry
/// point for text that a consumer holds: the trust of the layer, the scope
/// of the partials, the quarantined spans, the one set of untrusted limits,
/// and the injected well-known values.
@Suite struct StenciledDotfolderStackRenderTests {
  typealias Fixture = DotfolderStackTests.Fixture

  /// A body that uses a tag that the untrusted whitelist refuses. A trusted
  /// render gives the year with four digits.
  private static let nowTagBody = "{% now \"yyyy\" %}"

  /// A body that includes the `header` partial.
  private static let includeHeaderBody = "{% include \"header\" %}"

  /// The name of the partial file that the include tests write.
  private static let headerPartialPath = "_partials/header.md"

  /// A directory that no test writes. A layer that carries it names the
  /// trust of a render and nothing more: a quarantined span resolves no
  /// include, thus the render reads no file of this root.
  private static let unusedRoot = URL(fileURLWithPath: "/no-such-root", isDirectory: true)

  /// Fixed well-known values, so a render never depends on the state of the
  /// machine that runs the test.
  private static let fixtureWellKnownValues = WellKnownValues(
    workingDirectory: "/fixture/cwd", date: "2020-01-01", hostname: "fixture-host")

  /// The number of iterations of the loop that one budget span runs.
  private static let budgetLoopIterationCount = 1_500

  /// The text that each iteration of that loop writes.
  private static let budgetLoopChunk = "0123456789abcdef"

  /// One loop that writes `budgetLoopIterationCount` copies of
  /// `budgetLoopChunk`: 24 KiB, far below the output limit of an untrusted
  /// render, and far below its limit of the loop count.
  private static let budgetLoopFragment =
    "{% for i in 1...\(budgetLoopIterationCount) %}\(budgetLoopChunk){% endfor %}"

  /// The number of spans whose loops together write more than the output
  /// limit of one untrusted render.
  private static let budgetSpanCount = 50

  /// The number of quarantined spans of the text that shows that many spans
  /// are one template and thus one render.
  private static let manySpanCount = 1_000

  /// A stenciled stack over `base`, with fixed well-known values.
  private static func makeStenciled(
    over base: DotfolderStack,
    variables: [String: String] = [:],
    wellKnownValues: WellKnownValues? = fixtureWellKnownValues
  ) -> StenciledDotfolderStack {
    StenciledDotfolderStack(base: base, variables: variables, wellKnownValues: wellKnownValues)
  }

  /// The layer of a document of the project of `fixture`, which renders
  /// untrusted.
  private static func projectLayer(of fixture: Fixture) -> DotfolderStack.Layer {
    DotfolderStack.Layer(source: .project, root: fixture.projectDirectory)
  }

  /// A text of `spanCount` quarantined spans, each one after a copy of
  /// `originalText`.
  private static func repeatedSpans(
    _ originalText: String, quarantined: String, count spanCount: Int
  ) -> QuarantinedText {
    QuarantinedText(
      spans: (0..<spanCount).flatMap { _ in
        [QuarantinedText.Span.original(originalText), .quarantined(quarantined)]
      })
  }

  // MARK: - The trust of the layer

  @Test func consumerTextOfADefaultsLayerRendersTrusted() throws {
    let fixture = Fixture()
    let stenciled = Self.makeStenciled(over: fixture.makeStack())
    let yearShape = /\d{4}/

    let rendered = try stenciled.render(
      Self.nowTagBody,
      in: DotfolderStack.Layer(source: .defaults, root: fixture.defaultsDirectory))

    #expect(rendered.wholeMatch(of: yearShape) != nil)
  }

  @Test func consumerTextOfAProjectLayerRendersUntrustedAndRefusesTheTag() throws {
    let fixture = Fixture()
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    let error = try #require(throws: TemplateEngineError.self) {
      try stenciled.render(Self.nowTagBody, in: Self.projectLayer(of: fixture))
    }

    #expect(error.description.contains("now"))
  }

  // MARK: - The scope of the partials

  @Test func consumerTextOfAMarketplaceLayerNeverIncludesThePartialOfAnotherMarketplace() throws {
    let fixture = Fixture()
    let firstDirectory = fixture.root.appendingPathComponent("marketplace-one", isDirectory: true)
    let secondDirectory = fixture.root.appendingPathComponent("marketplace-two", isDirectory: true)
    fixture.write("first header", to: Self.headerPartialPath, in: firstDirectory)
    fixture.write("second header", to: Self.headerPartialPath, in: secondDirectory)
    let firstLayer = DotfolderStack.Layer(source: .marketplace, root: firstDirectory)
    var stack = fixture.makeStack()
    stack.layers.insert(
      contentsOf: [firstLayer, DotfolderStack.Layer(source: .marketplace, root: secondDirectory)],
      at: 0)
    let stenciled = Self.makeStenciled(over: stack)

    #expect(try stenciled.render(Self.includeHeaderBody, in: firstLayer) == "first header")
  }

  @Test func aLocalPartialWinsOverTheMarketplacePartialOfTheSameNameForConsumerText() throws {
    let fixture = Fixture()
    let marketplaceDirectory = fixture.root.appendingPathComponent(
      "marketplace", isDirectory: true)
    fixture.write("market header", to: Self.headerPartialPath, in: marketplaceDirectory)
    fixture.write("user header", to: Self.headerPartialPath, in: fixture.userDirectory)
    let marketplaceLayer = DotfolderStack.Layer(
      source: .marketplace, root: marketplaceDirectory)
    var stack = fixture.makeStack()
    stack.layers.insert(marketplaceLayer, at: 0)
    let stenciled = Self.makeStenciled(over: stack)

    #expect(try stenciled.render(Self.includeHeaderBody, in: marketplaceLayer) == "user header")
  }

  @Test func consumerTextOfALocalLayerNeverIncludesAPartialThatOnlyAMarketplaceHolds() throws {
    let fixture = Fixture()
    let marketplaceDirectory = fixture.root.appendingPathComponent(
      "marketplace", isDirectory: true)
    fixture.write("market header", to: Self.headerPartialPath, in: marketplaceDirectory)
    var stack = fixture.makeStack()
    stack.layers.insert(
      DotfolderStack.Layer(source: .marketplace, root: marketplaceDirectory), at: 0)
    let stenciled = Self.makeStenciled(over: stack)

    #expect(throws: TemplateEngineError.self) {
      try stenciled.render(Self.includeHeaderBody, in: Self.projectLayer(of: fixture))
    }
  }

  // MARK: - A quarantined span is data

  @Test(
    "a quarantined span that holds template syntax comes out byte for byte",
    arguments: [
      DotfolderStack.Layer(
        source: .defaults, root: StenciledDotfolderStackRenderTests.unusedRoot),
      DotfolderStack.Layer(
        source: .project, root: StenciledDotfolderStackRenderTests.unusedRoot),
    ])
  func aQuarantinedSpanIsCopiedWhateverTheTrust(layer: DotfolderStack.Layer) throws {
    let fixture = Fixture()
    fixture.write("header text", to: Self.headerPartialPath, in: fixture.defaultsDirectory)
    let stenciled = Self.makeStenciled(
      over: fixture.makeStack(), variables: ["secret": "from-variables"])
    let spliced = "{{ secret }} \(Self.includeHeaderBody)"
    let text = QuarantinedText(spans: [.original("value: "), .quarantined(spliced)])

    #expect(try stenciled.render(text, in: layer) == "value: \(spliced)")
  }

  @Test func aSplicedValueSpelledLikeTheQuarantineKeyStaysLiteral() throws {
    let fixture = Fixture()
    let key = "\(StenciledDotfolderStack.quarantinedSpanContextKeyPrefix)0"
    let stenciled = Self.makeStenciled(
      over: fixture.makeStack(), variables: [key: "from-variables"])
    let spliced = "{{ \(key) }}"
    let text = QuarantinedText(spans: [
      .quarantined(spliced), .original(" and "), .quarantined(spliced),
    ])

    #expect(
      try stenciled.render(text, in: Self.projectLayer(of: fixture)) == "\(spliced) and \(spliced)")
  }

  @Test func aStencilBlockMayStraddleAQuarantinedSpan() throws {
    let fixture = Fixture()
    let stenciled = Self.makeStenciled(over: fixture.makeStack(), variables: ["flag": "yes"])
    let text = QuarantinedText(spans: [
      .original("{% if flag %}before "), .quarantined("VALUE"), .original(" after{% endif %}"),
    ])

    #expect(
      try stenciled.render(text, in: Self.projectLayer(of: fixture)) == "before VALUE after")
  }

  // MARK: - A splice may never form template syntax

  @Test(
    "a quarantined span inside an open delimiter is a render failure",
    arguments: [
      (opener: "{{ ", closer: " }}"),
      (opener: "{{", closer: "}}"),
      (opener: "{% if ", closer: " %}yes{% endif %}"),
      (opener: "{# ", closer: " #}"),
    ])
  func aSpliceInsideAnOpenDelimiterIsARenderFailure(opener: String, closer: String) throws {
    let fixture = Fixture()
    let stenciled = Self.makeStenciled(over: fixture.makeStack())
    let text = QuarantinedText(spans: [
      .original(opener), .quarantined("value"), .original(closer),
    ])

    #expect(throws: TemplateEngineError.self, "\(opener)value\(closer)") {
      try stenciled.render(text, in: Self.projectLayer(of: fixture))
    }
  }

  @Test func aBareBraceBeforeASpliceStaysLiteral() throws {
    let fixture = Fixture()
    let stenciled = Self.makeStenciled(over: fixture.makeStack())
    let text = QuarantinedText(spans: [
      .original("{"), .quarantined("value"), .original("}"),
    ])

    #expect(try stenciled.render(text, in: Self.projectLayer(of: fixture)) == "{value}")
  }

  // MARK: - One text is one render, thus one set of the untrusted limits

  @Test func manyQuarantinedSpansOfAnUntrustedTextRenderAsOneTemplate() throws {
    let fixture = Fixture()
    let stenciled = Self.makeStenciled(over: fixture.makeStack())
    let text = Self.repeatedSpans(".", quarantined: "{{ x }}", count: Self.manySpanCount)

    #expect(try stenciled.render(text, in: Self.projectLayer(of: fixture)) == text.flattened)
  }

  @Test func oneSpanOfTheBudgetLoopRendersSoTheFixtureIsValidTemplateText() throws {
    let fixture = Fixture()
    let stenciled = Self.makeStenciled(over: fixture.makeStack())
    let text = Self.repeatedSpans(Self.budgetLoopFragment, quarantined: "q", count: 1)

    let rendered = try stenciled.render(text, in: Self.projectLayer(of: fixture))

    #expect(
      rendered.utf8.count
        == Self.budgetLoopIterationCount * Self.budgetLoopChunk.utf8.count + 1)
  }

  @Test func everySpanOfAnUntrustedTextDrawsOnOneOutputBudget() throws {
    let fixture = Fixture()
    let stenciled = Self.makeStenciled(over: fixture.makeStack())
    let text = Self.repeatedSpans(
      Self.budgetLoopFragment, quarantined: "q", count: Self.budgetSpanCount)

    #expect(throws: TemplateEngineError.self) {
      try stenciled.render(text, in: Self.projectLayer(of: fixture))
    }
  }

  // MARK: - The well-known values

  @Test func theInjectedWellKnownValuesRenderForConsumerText() throws {
    let fixture = Fixture()
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    let rendered = try stenciled.render(
      "{{ working_directory }}|{{ date }}|{{ hostname }}",
      in: Self.projectLayer(of: fixture))

    #expect(rendered == "/fixture/cwd|2020-01-01|fixture-host")
  }

  @Test func theInjectedWellKnownValuesRenderForAFile() {
    let fixture = Fixture()
    fixture.write("{{ hostname }}", to: "review/SKILL.md", in: fixture.projectDirectory)
    let stenciled = Self.makeStenciled(over: fixture.makeStack())

    #expect(stenciled.content("review/SKILL.md") == "fixture-host")
  }

  @Test func aVariableWinsOverAnInjectedWellKnownValueOfTheSameName() throws {
    let fixture = Fixture()
    let stenciled = Self.makeStenciled(
      over: fixture.makeStack(), variables: ["hostname": "from-variables"])

    #expect(
      try stenciled.render("{{ hostname }}", in: Self.projectLayer(of: fixture))
        == "from-variables")
  }

  @Test func noInjectedValuesMeansTheCurrentValuesAtEachRender() throws {
    let fixture = Fixture()
    let stenciled = Self.makeStenciled(over: fixture.makeStack(), wellKnownValues: nil)

    #expect(
      try stenciled.render("{{ working_directory }}", in: Self.projectLayer(of: fixture))
        == FileManager.default.currentDirectoryPath)
  }
}
