import Foundation
import Testing

@testable import FoundationModelsExtras

/// Golden tests pinning the swissarmyhammer content carryover (plan.md §4):
/// every templated file under `Fixtures/Corpus/` — a migrated copy of the
/// *templated* subset of `../swissarmyhammer/builtin/` (files using `{{ }}`/
/// `{% %}`, plus every partial they transitively reference) — renders
/// through `TemplateEngine` byte-for-byte to its checked-in expected output
/// (`Fixtures/Expected/` and `Fixtures/ExpectedAbsent/`, mirroring the
/// corpus's relative layout), under both trust levels.
///
/// ## The one-time corpus migration
///
/// A corpus audit (kanban task 9th0c05) found two constructs that could not
/// carry over verbatim, both fixed directly in the checked-in fixture copies
/// (not at render time):
///
/// - `_partials/coding-standards.md`: the corpus's one `{% render %}` tag
///   (Liquid-only; Stencil has no `render` tag at all — it would fail to
///   parse) became `{% include %}`, Stencil's equivalent.
/// - `_partials/skills.md`: `available_skills.size` became
///   `available_skills.count` — `.size` is a Liquid-ism Stencil does not
///   recognize, so `{% if available_skills.size > 0 %}` silently always
///   evaluated false (the `## Skills` section would never have rendered,
///   for *any* input) had it shipped unmigrated.
///
/// `migratedConstructsNoLongerAppearInTheCorpusAndRenderCorrectly` below
/// pins both fixes directly; the full golden mirror (`corpusFiles()`,
/// enumerated below) pins them again as part of the whole corpus.
///
/// ## The `available_skills`/`arguments` branch pinning
///
/// Exactly three corpus files branch on context (a second corpus-audit
/// finding): `_partials/skills.md` (`{% if %}`/`{% for %}` over
/// `available_skills`), `skills/ci/SKILL.md`, and `skills/map/SKILL.md`
/// (both `{% if arguments %}`). Rather than hand-listing those three and
/// special-casing them, every corpus file is rendered — and its output
/// pinned — under *both* context variants (`populatedContext`/
/// `absentContext`), via the same enumeration-driven loop: files that don't
/// branch simply render identically both times, and any future corpus file
/// that starts branching on these variables is covered automatically, with
/// no test change required.
@Suite struct CorpusGoldenTests {
  // MARK: - Fixture roots

  private static let fixturesRoot =
    PackageRootValidation.packageRoot()
    .appendingPathComponent("Tests/FoundationModelsExtrasTests/Fixtures", isDirectory: true)

  /// The migrated corpus: every templated file from
  /// `../swissarmyhammer/builtin/` plus every partial it references,
  /// preserving relative layout (`_partials/`, `agents/`, `skills/`,
  /// `validators/`).
  private static let corpusRoot = fixturesRoot.appendingPathComponent("Corpus", isDirectory: true)

  /// The checked-in expected output mirror for `populatedContext()`.
  private static let expectedPopulatedRoot = fixturesRoot.appendingPathComponent(
    "Expected", isDirectory: true)

  /// The checked-in expected output mirror for `absentContext()` — pins
  /// every `{% if %}` site's false branch.
  private static let expectedAbsentRoot = fixturesRoot.appendingPathComponent(
    "ExpectedAbsent", isDirectory: true)

  /// Set `CORPUS_GOLDEN_UPDATE=1` to (re)write the checked-in expected
  /// output mirrors from the engine's current rendering of the corpus,
  /// instead of comparing against them — the golden-file update path
  /// (mirrors `insta`/Go's `-update` convention). Always hand-review the
  /// resulting `git diff` before committing: this flag regenerates, it
  /// never itself validates.
  private static let regenerateGoldens =
    ProcessInfo.processInfo.environment["CORPUS_GOLDEN_UPDATE"] == "1"

  /// Deterministic well-known values so the golden output never depends on
  /// real process state (current directory, real date, real hostname).
  private static let fixtureWellKnownValues = WellKnownValues(
    workingDirectory: "/fixture/cwd",
    date: "2020-01-01",
    hostname: "fixture-host",
    dotfolderName: nil
  )

  // MARK: - Engine and contexts

  /// An engine whose `{% include %}` partials resolve through the corpus
  /// root's own `_partials/` (the corpus fixture is itself a single
  /// `DotfolderStack` layer, mirroring `DotfolderLoaderTests`' fixture
  /// convention), with deterministic environment and well-known values.
  private static func makeEngine() -> TemplateEngine {
    let nonexistentRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("CorpusGoldenTests-unused", isDirectory: true)
    let stack = DotfolderStack(
      name: "corpus",
      workingDirectory: nonexistentRoot,
      defaultsDirectory: corpusRoot,
      userDirectory: nonexistentRoot.appendingPathComponent("unused-user", isDirectory: true),
      environment: [:]
    )
    return TemplateEngine(
      partials: stack, environment: [:], wellKnownValues: fixtureWellKnownValues)
  }

  /// The "truthy" branch variant: a small fixed `available_skills` array
  /// (exercising the `{% for %}` over it too), non-empty `arguments`, and a
  /// fixed `version`.
  private static func populatedContext() -> TemplateContext {
    var context = TemplateContext()
    context.set(key: "version", to: .string("1.0.0"))
    context.set(key: "arguments", to: .string("src/Widget.swift"))
    context.set(
      key: "available_skills",
      to: .array([
        .dictionary([
          "name": .string("coverage"),
          "description": .string("Finds coverage gaps"),
          "source": .string("project"),
        ]),
        .dictionary([
          "name": .string("shell"),
          "description": .string("Runs shell commands"),
          "source": .string("builtin"),
        ]),
      ])
    )
    return context
  }

  /// The "absent" branch variant: `available_skills` and `arguments` are
  /// simply not set (not present-but-empty) — Stencil resolves an absent
  /// dotted lookup (`available_skills.count`) and an absent bare variable
  /// (`arguments`) to `nil` without error, and both the `{% if %}` and
  /// `{% for %}` tags treat `nil` as falsy/empty, so this variant needs no
  /// special-casing beyond simply omitting the keys. `version` stays set
  /// so every file's frontmatter still substitutes identically to
  /// `populatedContext()` — only the branch-driving keys are absent.
  private static func absentContext() -> TemplateContext {
    var context = TemplateContext()
    context.set(key: "version", to: .string("1.0.0"))
    return context
  }

  // MARK: - Corpus enumeration

  /// Every regular file under `corpusRoot`, relative path, sorted for
  /// deterministic iteration order — the test's only "list" of corpus
  /// files; there is no hand-kept array to fall out of sync with the
  /// checked-in fixture tree.
  private static func corpusFiles() throws -> [String] {
    try FileManager.default.subpathsOfDirectory(atPath: corpusRoot.path)
      .filter { relativePath in
        var isDirectory: ObjCBool = false
        let fullPath = corpusRoot.appendingPathComponent(relativePath).path
        FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory)
        return !isDirectory.boolValue
      }
      .sorted()
  }

  // MARK: - Diffing

  /// A short description naming the first line where `actual` departs from
  /// `expected`, so a golden-test failure names the file (via the caller's
  /// message) and shows a diff, instead of dumping two whole-file blobs.
  private static func diffDescription(expected: String, actual: String) -> String {
    let expectedLines = expected.components(separatedBy: "\n")
    let actualLines = actual.components(separatedBy: "\n")
    let lineCount = max(expectedLines.count, actualLines.count)
    for index in 0..<lineCount {
      let expectedLine = index < expectedLines.count ? expectedLines[index] : "<no such line>"
      let actualLine = index < actualLines.count ? actualLines[index] : "<no such line>"
      if expectedLine != actualLine {
        return """
          first difference at line \(index + 1):
            expected: \(expectedLine)
            actual:   \(actualLine)
          """
      }
    }
    return
      "no line-level difference found (\(expectedLines.count) vs \(actualLines.count) lines — trailing newline?)"
  }

  // MARK: - The shared golden-comparison loop

  /// Renders every corpus file (trusted) under `context` and compares it
  /// to its checked-in expected output under `expectedRoot`, recording a
  /// non-fatal `Issue` per mismatch so one run reports every failing file,
  /// not just the first.
  private static func assertCorpusMatchesExpected(
    contextLabel: String,
    context: TemplateContext,
    expectedRoot: URL
  ) throws {
    let engine = Self.makeEngine()
    for relativePath in try Self.corpusFiles() {
      let sourceURL = Self.corpusRoot.appendingPathComponent(relativePath)
      let source = try String(contentsOf: sourceURL, encoding: .utf8)
      let rendered = try engine.render(source, context: context, trust: .trusted)

      let expectedURL = expectedRoot.appendingPathComponent(relativePath)
      if Self.regenerateGoldens {
        try FileManager.default.createDirectory(
          at: expectedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rendered.write(to: expectedURL, atomically: true, encoding: .utf8)
      }

      guard let expected = try? String(contentsOf: expectedURL, encoding: .utf8) else {
        Issue.record(
          """
          \(relativePath) (\(contextLabel) context): no checked-in expected output at \
          \(expectedURL.path). Run once with CORPUS_GOLDEN_UPDATE=1 to generate it, then \
          hand-review the diff before committing.
          """
        )
        continue
      }

      if rendered != expected {
        let diff = Self.diffDescription(expected: expected, actual: rendered)
        Issue.record(
          "\(relativePath) (\(contextLabel) context) does not match its expected output: \(diff)")
      }
    }
  }

  // MARK: - Tests

  @Test func everyCorpusFileRendersAndMatchesItsExpectedOutputUnderThePopulatedContext() throws {
    try Self.assertCorpusMatchesExpected(
      contextLabel: "populated", context: Self.populatedContext(),
      expectedRoot: Self.expectedPopulatedRoot)
  }

  @Test func everyCorpusFileRendersAndMatchesItsExpectedOutputUnderTheAbsentContext() throws {
    try Self.assertCorpusMatchesExpected(
      contextLabel: "absent", context: Self.absentContext(), expectedRoot: Self.expectedAbsentRoot)
  }

  @Test func everyCorpusFileRendersCleanlyUntrustedWithOutputIdenticalToTrusted() throws {
    // The corpus survey (plan.md §4) found zero filters and only
    // `include`/`if`/`for` tags in use — every construct
    // `Trust.untrusted` whitelists — so untrusted rendering should
    // succeed for the whole corpus and produce byte-identical output to
    // trusted rendering (no whitelist rejection ever fires).
    let engine = Self.makeEngine()
    let context = Self.populatedContext()
    for relativePath in try Self.corpusFiles() {
      let source = try String(
        contentsOf: Self.corpusRoot.appendingPathComponent(relativePath), encoding: .utf8)
      let trusted = try engine.render(source, context: context, trust: .trusted)
      let untrusted = try engine.render(source, context: context, trust: .untrusted)
      #expect(untrusted == trusted, "\(relativePath): untrusted output differs from trusted output")
    }
  }

  @Test func migratedConstructsNoLongerAppearInTheCorpusAndRenderCorrectly() throws {
    let engine = Self.makeEngine()

    let codingStandardsPath = "_partials/coding-standards.md"
    let codingStandards = try String(
      contentsOf: Self.corpusRoot.appendingPathComponent(codingStandardsPath), encoding: .utf8)
    #expect(!codingStandards.contains("{% render"))
    #expect(codingStandards.contains("{% include \"_partials/validators\" %}"))
    let renderedCodingStandards = try engine.render(
      codingStandards, context: Self.populatedContext(), trust: .trusted)
    // The migrated `{% include %}` actually pulled in `_partials/validators.md`'s content.
    #expect(renderedCodingStandards.contains("Validator Feedback"))

    let skillsPath = "_partials/skills.md"
    let skills = try String(
      contentsOf: Self.corpusRoot.appendingPathComponent(skillsPath), encoding: .utf8)
    #expect(!skills.contains(".size"))
    #expect(skills.contains("available_skills.count > 0"))
    let renderedWithSkills = try engine.render(
      skills, context: Self.populatedContext(), trust: .trusted)
    let renderedWithoutSkills = try engine.render(
      skills, context: Self.absentContext(), trust: .trusted)
    // Had `.size` shipped unmigrated, this branch would render "" in
    // *both* cases (Stencil silently resolves `.size` on an array to
    // nil, always false) — asserting the truthy/falsy outputs actually
    // differ is what proves the migration fixed the bug, not just that
    // neither branch throws.
    #expect(renderedWithSkills.contains("## Skills"))
    #expect(!renderedWithoutSkills.contains("## Skills"))
  }

  /// `validators/no-secrets/rules/no-secrets.md` documents `` `{{secret}}` ``
  /// as a literal example of a placeholder pattern the rule should *not*
  /// flag — prose, not a template variable. Stencil cannot tell the
  /// difference: an undefined variable renders as an empty string, so
  /// rendering this file through the engine silently eats the placeholder
  /// text down to an empty pair of backticks. The corpus audit (kanban
  /// task 9th0c05) considered excluding this file from the golden suite
  /// instead; this test deliberately pins the eaten-placeholder output —
  /// so the file stays part of the enumeration-driven golden mirror like
  /// every other corpus file (no special-cased exclusion list) — and
  /// documents, here and at its point of use, exactly why the output looks
  /// the way it does.
  @Test func noSecretsPlaceholderLiteralIsSilentlyEatenByStencilAndTheOutputIsDeliberatelyPinned()
    throws
  {
    let engine = Self.makeEngine()
    let relativePath = "validators/no-secrets/rules/no-secrets.md"
    let source = try String(
      contentsOf: Self.corpusRoot.appendingPathComponent(relativePath), encoding: .utf8)
    #expect(source.contains("`{{secret}}`"))

    let rendered = try engine.render(source, context: Self.populatedContext(), trust: .trusted)

    #expect(!rendered.contains("{{secret}}"))
    #expect(rendered.contains("`<YOUR_API_KEY>`, `${API_KEY}`, ``"))
  }
}
