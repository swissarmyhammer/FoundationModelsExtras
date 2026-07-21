import Foundation
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `LayeredYAMLDocument`: the family's one
/// layered-merge rule (plan.md §11) — scalar/array wholesale replacement
/// vs section merge-by-key across three fixture layers, per-key source
/// tracking, the malformed-layer hard error naming file and line, templated
/// values resolved per layer before merge, and the `YAMLValue` Codable
/// round-trip. Every test builds its own throwaway `defaults/`/`user/`/
/// `project/` tree under a temp directory (mirroring `DotfolderStackTests`'
/// `Fixture`) so nothing ever touches the real home directory.
@Suite struct LayeredYAMLDocumentTests {
  /// A throwaway three-layer directory tree, cleaned up when the OS
  /// reclaims the temp directory.
  struct Fixture {
    let root: URL
    let workingDirectory: URL
    let defaultsDirectory: URL
    let userDirectory: URL
    let projectDirectory: URL

    init() {
      let uncanonicalRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LayeredYAMLDocumentTests-\(UUID().uuidString)", isDirectory: true)
      try! FileManager.default.createDirectory(
        at: uncanonicalRoot, withIntermediateDirectories: true)
      root = canonicalize(uncanonicalRoot)
      workingDirectory = root.appendingPathComponent("workspace", isDirectory: true)
      defaultsDirectory = root.appendingPathComponent("defaults", isDirectory: true)
      userDirectory = root.appendingPathComponent("user", isDirectory: true)
      projectDirectory = workingDirectory.appendingPathComponent(".testagent", isDirectory: true)
      try! FileManager.default.createDirectory(
        at: defaultsDirectory, withIntermediateDirectories: true)
      try! FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
      try! FileManager.default.createDirectory(
        at: projectDirectory, withIntermediateDirectories: true)
    }

    func write(_ contents: String, to relativePath: String, in directory: URL) {
      let fileURL = directory.appendingPathComponent(relativePath)
      try! FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try! contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func makeStack(environment: [String: String] = [:]) -> DotfolderStack {
      DotfolderStack(
        name: "testagent",
        workingDirectory: workingDirectory,
        defaultsDirectory: defaultsDirectory,
        userDirectory: userDirectory,
        environment: environment
      )
    }

    /// A hermetic engine over this fixture's stack — no partials needed for
    /// these tests, so `partials` is left `nil`.
    func makeEngine() -> TemplateEngine {
      TemplateEngine(
        partials: nil,
        environment: ["HOME": "/fixture/home"],
        wellKnownValues: WellKnownValues(
          workingDirectory: workingDirectory.path, date: "2026-07-21", hostname: "fixture-host",
          dotfolderName: nil)
      )
    }
  }

  // MARK: - Scalar/array wholesale replacement vs section merge-by-key

  @Test func scalarKeyReplacesWholesaleAcrossLayers() throws {
    let fixture = Fixture()
    fixture.write("profile: standard\n", to: "config.yaml", in: fixture.defaultsDirectory)
    fixture.write("profile: custom\n", to: "config.yaml", in: fixture.userDirectory)
    fixture.write("profile: pro\n", to: "config.yaml", in: fixture.projectDirectory)

    let document = try LayeredYAMLDocument.load(
      "config.yaml", from: fixture.makeStack(), engine: fixture.makeEngine(),
      context: TemplateContext())

    #expect(document.root == .dictionary(["profile": .string("pro")]))
    #expect(document.source(of: ["profile"]) == .project)
  }

  @Test func arrayReplacesWholesaleNotConcatenatedAcrossLayers() throws {
    let fixture = Fixture()
    fixture.write("tags:\n  - alpha\n  - beta\n", to: "config.yaml", in: fixture.defaultsDirectory)
    fixture.write("tags:\n  - gamma\n", to: "config.yaml", in: fixture.userDirectory)

    let document = try LayeredYAMLDocument.load(
      "config.yaml", from: fixture.makeStack(), engine: fixture.makeEngine(),
      context: TemplateContext())

    // Arrays replace wholesale: the user layer's single-element array wins
    // outright, not `[alpha, beta, gamma]`.
    #expect(document.root == .dictionary(["tags": .array([.string("gamma")])]))
    #expect(document.source(of: ["tags"]) == .user)
  }

  @Test func dictionarySectionsMergeByKeyAcrossLayers() throws {
    let fixture = Fixture()
    fixture.write(
      "settings:\n  timeout: 30\n  retries: 3\n", to: "config.yaml", in: fixture.defaultsDirectory)
    fixture.write("settings:\n  retries: 5\n", to: "config.yaml", in: fixture.userDirectory)
    fixture.write("settings:\n  timeout: 60\n", to: "config.yaml", in: fixture.projectDirectory)

    let document = try LayeredYAMLDocument.load(
      "config.yaml", from: fixture.makeStack(), engine: fixture.makeEngine(),
      context: TemplateContext())

    #expect(
      document.root
        == .dictionary(["settings": .dictionary(["timeout": .int(60), "retries": .int(5)])]))
    #expect(document.source(of: ["settings", "timeout"]) == .project)
    #expect(document.source(of: ["settings", "retries"]) == .user)
  }

  // MARK: - Per-key source tracking

  @Test func sourceTrackingReportsNilForAKeyPathNoLayerEverTouched() throws {
    let fixture = Fixture()
    fixture.write("profile: standard\n", to: "config.yaml", in: fixture.defaultsDirectory)

    let document = try LayeredYAMLDocument.load(
      "config.yaml", from: fixture.makeStack(), engine: fixture.makeEngine(),
      context: TemplateContext())

    #expect(document.source(of: ["profile"]) == .defaults)
    #expect(document.source(of: ["nonexistent"]) == nil)
  }

  @Test func sourceTrackingAttributesAFreshlyIntroducedSectionToItsLayer() throws {
    let fixture = Fixture()
    fixture.write("profile: standard\n", to: "config.yaml", in: fixture.defaultsDirectory)
    fixture.write(
      "mcp:\n  servers:\n    demo:\n      command: echo\n", to: "config.yaml",
      in: fixture.projectDirectory)

    let document = try LayeredYAMLDocument.load(
      "config.yaml", from: fixture.makeStack(), engine: fixture.makeEngine(),
      context: TemplateContext())

    // `mcp` only exists in the project layer: the whole subtree (including
    // its own key path) is attributed to `.project`.
    #expect(document.source(of: ["mcp"]) == .project)
    #expect(document.source(of: ["mcp", "servers"]) == .project)
    #expect(document.source(of: ["mcp", "servers", "demo", "command"]) == .project)
  }

  // MARK: - Missing layers are simply absent

  @Test func missingLayersAreSimplyAbsentFromTheMerge() throws {
    let fixture = Fixture()
    fixture.write("profile: standard\n", to: "config.yaml", in: fixture.defaultsDirectory)
    fixture.write("profile: pro\n", to: "config.yaml", in: fixture.projectDirectory)
    // No user/config.yaml at all.

    let document = try LayeredYAMLDocument.load(
      "config.yaml", from: fixture.makeStack(), engine: fixture.makeEngine(),
      context: TemplateContext())

    #expect(document.root == .dictionary(["profile": .string("pro")]))
  }

  @Test func loadReturnsNullRootAndNoSourcesWhenNoLayerHasTheFile() throws {
    let fixture = Fixture()

    let document = try LayeredYAMLDocument.load(
      "config.yaml", from: fixture.makeStack(), engine: fixture.makeEngine(),
      context: TemplateContext())

    #expect(document.root == .null)
    #expect(document.source(of: []) == nil)
  }

  // MARK: - Malformed layer: hard error naming file + line

  @Test func malformedLayerIsAHardErrorNamingFileAndLine() throws {
    let fixture = Fixture()
    fixture.write("profile: standard\n", to: "config.yaml", in: fixture.defaultsDirectory)
    // Line 1 is fine; line 2 has an unterminated flow sequence.
    fixture.write(
      "profile: custom\nbroken: [1, 2\n", to: "config.yaml", in: fixture.userDirectory)

    #expect {
      _ = try LayeredYAMLDocument.load(
        "config.yaml", from: fixture.makeStack(), engine: fixture.makeEngine(),
        context: TemplateContext())
    } throws: { error in
      guard let documentError = error as? LayeredYAMLDocumentError else { return false }
      switch documentError {
      case .malformed(let path, let line, _):
        return path.hasSuffix("user/config.yaml") && line != nil
      default:
        return false
      }
    }
  }

  // MARK: - Templated values resolve per layer before merge

  @Test func templatedValuesResolvePerLayerBeforeMerge() throws {
    let fixture = Fixture()
    fixture.write("token: static-default\n", to: "config.yaml", in: fixture.defaultsDirectory)
    fixture.write("token: \"{{ HOME }}\"\n", to: "config.yaml", in: fixture.userDirectory)

    var context = TemplateContext()
    context.set(key: "extra", to: .string("ignored"))

    let document = try LayeredYAMLDocument.load(
      "config.yaml", from: fixture.makeStack(), engine: fixture.makeEngine(), context: context)

    #expect(document.root == .dictionary(["token": .string("/fixture/home")]))
    #expect(document.source(of: ["token"]) == .user)
  }

  @Test func explicitContextValuesRenderIntoLayerContentBeforeParsing() throws {
    let fixture = Fixture()
    fixture.write(
      "greeting: \"hello {{ name }}\"\n", to: "config.yaml", in: fixture.defaultsDirectory)

    var context = TemplateContext()
    context.set(key: "name", to: .string("world"))

    let document = try LayeredYAMLDocument.load(
      "config.yaml", from: fixture.makeStack(), engine: fixture.makeEngine(), context: context)

    #expect(document.root == .dictionary(["greeting": .string("hello world")]))
  }

  // MARK: - Trust split: trusted defaults, untrusted user/project

  @Test func defaultsLayerRendersTrustedWhileProjectLayerRendersUntrusted() throws {
    let fixture = Fixture()
    // `now` is a real Stencil tag but is not in the untrusted whitelist, so
    // it renders fine trusted (defaults) but fails to render untrusted
    // (project).
    fixture.write(
      "stamp: \"{% now \\\"yyyy\\\" %}\"\n", to: "config.yaml", in: fixture.defaultsDirectory)

    // Rendering trusted succeeds — `now` is a real Stencil tag not on the
    // untrusted whitelist, so this only proves anything once contrasted
    // with the untrusted (project-layer) failure below.
    let trustedOnlyDocument = try LayeredYAMLDocument.load(
      "config.yaml", from: fixture.makeStack(), engine: fixture.makeEngine(),
      context: TemplateContext())
    guard case .dictionary(let values) = trustedOnlyDocument.root, values["stamp"] != nil else {
      Issue.record("expected a rendered 'stamp' key from the trusted defaults layer")
      return
    }

    let projectFixture = Fixture()
    projectFixture.write(
      "stamp: \"{% now \\\"yyyy\\\" %}\"\n", to: "config.yaml", in: projectFixture.projectDirectory)

    #expect(throws: LayeredYAMLDocumentError.self) {
      _ = try LayeredYAMLDocument.load(
        "config.yaml", from: projectFixture.makeStack(), engine: projectFixture.makeEngine(),
        context: TemplateContext())
    }
  }

  // MARK: - Codable round-trip

  private struct FixtureConfig: Decodable, Equatable {
    struct Settings: Decodable, Equatable {
      let timeout: Int
      let retries: Int
    }
    let profile: String
    let tags: [String]
    let settings: Settings
    let enabled: Bool
    let ratio: Double
  }

  @Test func mergedRootRoundTripsIntoAFixtureCodableSchema() throws {
    let fixture = Fixture()
    fixture.write(
      """
      profile: standard
      tags:
        - alpha
      settings:
        timeout: 30
        retries: 3
      enabled: false
      ratio: 1.5
      """, to: "config.yaml", in: fixture.defaultsDirectory)
    fixture.write(
      """
      profile: pro
      tags:
        - gamma
        - delta
      settings:
        retries: 9
      enabled: true
      """, to: "config.yaml", in: fixture.projectDirectory)

    let document = try LayeredYAMLDocument.load(
      "config.yaml", from: fixture.makeStack(), engine: fixture.makeEngine(),
      context: TemplateContext())

    let decoded = try document.root.decoded(as: FixtureConfig.self)

    #expect(
      decoded
        == FixtureConfig(
          profile: "pro", tags: ["gamma", "delta"],
          settings: .init(timeout: 30, retries: 9), enabled: true, ratio: 1.5))
  }
}
