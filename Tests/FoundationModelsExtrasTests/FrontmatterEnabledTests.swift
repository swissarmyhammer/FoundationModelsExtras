import Foundation
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for the `enabled` frontmatter key: the rule of
/// `FrontmatterEnablement`, the enablement of each document of a
/// `FrontmatterDocumentStack`, and the view of the enabled documents after
/// the layer shadowing. Every test builds its own throwaway three-layer tree
/// through `DotfolderStackTests.Fixture`.
@Suite struct FrontmatterEnabledTests {
  typealias Fixture = DotfolderStackTests.Fixture

  /// A full document that is on.
  private static let fullDocument = "---\nname: review\ndescription: reviews\n---\n# Review\n"

  /// A stub that only turns its item off.
  private static let offStub = "---\nenabled: false\n---\n"

  /// A stack over the fixture's plain stack whose metadata is the raw
  /// frontmatter text, and that records its diagnostics in `log`.
  private static func makeRawStack(
    _ fixture: Fixture, log: DiagnosticLog = DiagnosticLog()
  ) -> FrontmatterDocumentStack<DotfolderStack, String> {
    FrontmatterDocumentStack(base: fixture.makeStack(), decode: { $0 }, onDiagnostic: { log.record($0) })
  }

  // MARK: - The rule

  @Test func theRuleReadsTheKeyFromTheRawFrontmatter() {
    #expect(FrontmatterEnablement(frontmatter: "name: review\n") == .enabled)
    #expect(FrontmatterEnablement(frontmatter: "enabled: true\n") == .enabled)
    #expect(FrontmatterEnablement(frontmatter: "enabled: false\n") == .disabled)
    #expect(FrontmatterEnablement(frontmatter: "") == .enabled)
    #expect(FrontmatterEnablement(frontmatter: "- a\n- b\n") == .enabled)
    #expect(FrontmatterEnablement(frontmatter: "name: [unclosed\n") == .enabled)
    #expect(FrontmatterEnablement.key == "enabled")
  }

  @Test func aValueThatIsNotABoolFailsClosed() {
    for text in ["enabled: \"false\"\n", "enabled: 0\n", "enabled: [a]\n", "enabled:\n"] {
      let enablement = FrontmatterEnablement(frontmatter: text)

      #expect(!enablement.isEnabled, "\(text)")
      guard case .invalid(let message) = enablement else {
        Issue.record("\(text) gave \(enablement)")
        continue
      }
      #expect(message.contains("enabled"))
    }
  }

  @Test func theRuleReadsADecodedMapping() {
    #expect(FrontmatterEnablement(mapping: nil) == .enabled)
    #expect(FrontmatterEnablement(mapping: .dictionary(["name": .string("x")])) == .enabled)
    #expect(FrontmatterEnablement(mapping: .dictionary(["enabled": .bool(true)])) == .enabled)
    #expect(FrontmatterEnablement(mapping: .dictionary(["enabled": .bool(false)])) == .disabled)
    #expect(FrontmatterEnablement(mapping: .array([.string("a")])) == .enabled)
    #expect(!FrontmatterEnablement(mapping: .dictionary(["enabled": .string("no")])).isEnabled)
    #expect(FrontmatterEnablement.enabled.isEnabled)
    #expect(!FrontmatterEnablement.disabled.isEnabled)
  }

  @Test func aDocumentMadeWithNoEnablementIsEnabled() {
    let document = FrontmatterDocument<String>(metadata: nil, content: "x")

    #expect(document.isEnabled)
    #expect(document.enablement == .enabled)
    #expect(!FrontmatterDocument<String>(metadata: nil, content: "x", enablement: .disabled).isEnabled)
  }

  // MARK: - The stack

  @Test func aDocumentWithNoFrontmatterOrNoKeyIsEnabled() {
    let fixture = Fixture()
    fixture.write("# Plain\n", to: "plain/SKILL.md", in: fixture.projectDirectory)
    fixture.write(Self.fullDocument, to: "review/SKILL.md", in: fixture.projectDirectory)
    let log = DiagnosticLog()
    let documents = Self.makeRawStack(fixture, log: log)

    #expect(documents.item(at: "plain/SKILL.md")?.value.isEnabled == true)
    #expect(documents.item(at: "review/SKILL.md")?.value.isEnabled == true)
    #expect(log.diagnostics.isEmpty)
  }

  @Test func enabledFalseTurnsTheDocumentOffWithEachDecode() {
    let fixture = Fixture()
    fixture.write(
      "---\nname: review\nenabled: false\n---\n# Review\n", to: "review/SKILL.md", in: fixture.projectDirectory)
    let raw = Self.makeRawStack(fixture)
    let yaml = FrontmatterDocumentStack(base: fixture.makeStack())

    #expect(raw.item(at: "review/SKILL.md")?.value.enablement == .disabled)
    #expect(raw.item(at: "review/SKILL.md")?.value.metadata == "name: review\nenabled: false\n")
    #expect(yaml.item(at: "review/SKILL.md")?.value.enablement == .disabled)
    #expect(yaml.item(at: "review/SKILL.md")?.value.metadata == .dictionary(["name": .string("review"), "enabled": .bool(false)]))
  }

  @Test func aValueThatIsNotABoolGivesOneDiagnosticAndTurnsTheDocumentOff() {
    let fixture = Fixture()
    fixture.write("---\nenabled: \"no\"\n---\n", to: "review/SKILL.md", in: fixture.projectDirectory)
    let log = DiagnosticLog()
    let documents = FrontmatterDocumentStack<DotfolderStack, String>(
      base: fixture.makeStack(), decode: { _ in nil }, onDiagnostic: { log.record($0) })

    let document = documents.item(at: "review/SKILL.md")

    #expect(document?.value.isEnabled == false)
    #expect(log.diagnostics.count == 1)
    #expect(log.diagnostics.first?.url == document?.url)
    #expect(log.diagnostics.first?.layer.source == .project)
    #expect(log.diagnostics.first?.message.contains("enabled") == true)
  }

  @Test func aStubInAHigherLayerTurnsOffTheLowerCopy() {
    let fixture = Fixture()
    fixture.write(Self.fullDocument, to: "review/SKILL.md", in: fixture.defaultsDirectory)
    fixture.write(Self.fullDocument, to: "lint/SKILL.md", in: fixture.defaultsDirectory)
    fixture.write(Self.offStub, to: "review/SKILL.md", in: fixture.projectDirectory)
    let documents = Self.makeRawStack(fixture)

    let enabled = documents.enabledItems(named: "SKILL.md")
    let all = documents.items(named: "SKILL.md")
    let enabledTree = documents.enabledTree()

    #expect(Set(enabled.keys) == ["lint"])
    #expect(Set(all.keys) == ["lint", "review"])
    #expect(all["review"]?.value.isEnabled == false)
    #expect(all["review"]?.layer.source == .project)
    #expect(Set(enabledTree.keys) == ["lint/SKILL.md"])
    #expect(Set(documents.tree().keys) == ["lint/SKILL.md", "review/SKILL.md"])
  }

  @Test func aDisabledStubGivesNoDecodeDiagnostic() {
    let fixture = Fixture()
    fixture.write(Self.offStub, to: "review/SKILL.md", in: fixture.projectDirectory)
    let log = DiagnosticLog()
    let documents = FrontmatterDocumentStack<DotfolderStack, String>(
      base: fixture.makeStack(), decode: { _ in nil }, onDiagnostic: { log.record($0) })

    let document = documents.item(at: "review/SKILL.md")

    #expect(document?.value.isEnabled == false)
    #expect(document?.value.metadata == nil)
    #expect(log.diagnostics.isEmpty)
  }

  @Test func malformedYAMLStaysEnabledWithOnlyTheDecodeDiagnostic() {
    let fixture = Fixture()
    fixture.write("---\nname: [unclosed\n---\n# Body\n", to: "review/SKILL.md", in: fixture.projectDirectory)
    let log = DiagnosticLog()
    let documents = FrontmatterDocumentStack(base: fixture.makeStack(), onDiagnostic: { log.record($0) })

    let document = documents.item(at: "review/SKILL.md")

    #expect(document?.value.isEnabled == true)
    #expect(document?.value.metadata == nil)
    #expect(log.diagnostics.count == 1)
  }
}
