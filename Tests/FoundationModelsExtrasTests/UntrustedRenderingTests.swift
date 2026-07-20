import Foundation
import Stencil
import Testing

@testable import FoundationModelsExtras

#if canImport(Darwin)
  import Darwin
#endif

/// Resolves `url` to its real, firmlink-free path via POSIX `realpath(3)` —
/// mirrors `DotfolderLoaderTests`' helper of the same name, for the same
/// reason (see that file's comment).
private func canonicalize(_ url: URL) -> URL {
  var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
  guard realpath(url.path, &buffer) != nil else { return url }
  let nullTerminatorIndex = buffer.firstIndex(of: 0) ?? buffer.count
  let path = String(
    decoding: buffer[..<nullTerminatorIndex].map(UInt8.init(bitPattern:)), as: UTF8.self)
  return URL(fileURLWithPath: path, isDirectory: true)
}

/// Behavioral tests for `Trust.untrusted` (plan.md §4): the tag/filter
/// whitelist, the loader's confinement to `_partials/`, the include-depth
/// limit, and the output-size limit — every acceptance criterion for the
/// restricted `Environment`, including the trusted-vs-untrusted contrast on
/// the same template text.
@Suite struct UntrustedRenderingTests {
  /// A throwaway single-layer directory tree with its own `_partials/`,
  /// cleaned up when the test ends (the OS reclaims the temp directory;
  /// nothing here removes it explicitly, matching `DotfolderLoaderTests`).
  struct Fixture {
    let workingDirectory: URL
    let projectDirectory: URL

    init() {
      let uncanonicalRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("UntrustedRenderingTests-\(UUID().uuidString)", isDirectory: true)
      try! FileManager.default.createDirectory(
        at: uncanonicalRoot, withIntermediateDirectories: true)
      let root = canonicalize(uncanonicalRoot)
      workingDirectory = root.appendingPathComponent("workspace", isDirectory: true)
      projectDirectory = workingDirectory.appendingPathComponent(".testagent", isDirectory: true)
      try! FileManager.default.createDirectory(
        at: projectDirectory, withIntermediateDirectories: true)
    }

    /// Writes `contents` to `_partials/<name>` under the project layer.
    func writePartial(_ contents: String, named name: String) {
      let fileURL = projectDirectory.appendingPathComponent("_partials").appendingPathComponent(
        name)
      try! FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try! contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Writes `contents` directly under the project layer root (i.e.
    /// *outside* `_partials/`) — a "secret" a path-traversal include
    /// might try to reach.
    func writeSecret(_ contents: String, named name: String) {
      let fileURL = projectDirectory.appendingPathComponent(name)
      try! contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// An engine wired with this fixture's stack as `partials`.
    func makeEngine() -> TemplateEngine {
      let stack = DotfolderStack(
        name: "testagent", workingDirectory: workingDirectory, environment: [:])
      return TemplateEngine(partials: stack)
    }
  }

  // MARK: - Tag whitelist

  @Test func nonWhitelistedTagRendersTrustedButThrowsUntrusted() throws {
    let engine = Fixture().makeEngine()
    let template = "{% now \"yyyy\" %}"

    // Renders under `.trusted` (a real date string; exact value doesn't
    // matter, only that it doesn't throw).
    _ = try engine.render(template, context: TemplateContext(), trust: .trusted)

    do {
      _ = try engine.render(template, context: TemplateContext(), trust: .untrusted)
      Issue.record("expected TemplateEngineError to be thrown")
    } catch let error as TemplateEngineError {
      #expect("\(error)".contains("now"))
    } catch {
      Issue.record("expected TemplateEngineError, got \(error)")
    }
  }

  @Test func nonWhitelistedTagInsideAnUnexecutedBranchStillThrowsUntrusted() {
    let engine = Fixture().makeEngine()
    // The `{% now %}` never executes (flag is false), but the whitelist
    // check runs over lexed tokens, not parsed/executed nodes, so it is
    // still rejected.
    let template = "{% if flag %}{% now %}{% endif %}"

    #expect(throws: TemplateEngineError.self) {
      _ = try engine.render(template, context: TemplateContext(), trust: .untrusted)
    }
  }

  // MARK: - Filter whitelist

  @Test func nonWhitelistedFilterRendersTrustedButThrowsUntrusted() throws {
    let engine = Fixture().makeEngine()
    var context = TemplateContext()
    context.set(key: "name", to: .string("world"))
    let template = "{{ name|uppercase }}"

    let trustedRendered = try engine.render(template, context: context, trust: .trusted)
    #expect(trustedRendered == "WORLD")

    do {
      _ = try engine.render(template, context: context, trust: .untrusted)
      Issue.record("expected TemplateEngineError to be thrown")
    } catch let error as TemplateEngineError {
      #expect("\(error)".contains("uppercase"))
    } catch {
      Issue.record("expected TemplateEngineError, got \(error)")
    }
  }

  // MARK: - Loader confined to `_partials/`

  @Test func includeWithParentDirectoryTraversalIsRejectedUntrusted() {
    let fixture = Fixture()
    fixture.writeSecret("top secret", named: "secrets.md")
    let engine = fixture.makeEngine()

    do {
      let rendered = try engine.render(
        "{% include \"../secrets.md\" %}", context: TemplateContext(), trust: .untrusted)
      Issue.record("expected a throw, got \(rendered)")
    } catch let error as TemplateEngineError {
      #expect(!"\(error)".contains("top secret"))
    } catch {
      Issue.record("expected TemplateEngineError, got \(error)")
    }
  }

  @Test func includeWithAnAbsolutePathIsRejectedUntrusted() {
    let fixture = Fixture()
    fixture.writeSecret("top secret", named: "secrets.md")
    let engine = fixture.makeEngine()
    let absolutePath = fixture.projectDirectory.appendingPathComponent("secrets.md").path

    do {
      let rendered = try engine.render(
        "{% include \"\(absolutePath)\" %}", context: TemplateContext(), trust: .untrusted)
      Issue.record("expected a throw, got \(rendered)")
    } catch let error as TemplateEngineError {
      #expect(!"\(error)".contains("top secret"))
    } catch {
      Issue.record("expected TemplateEngineError, got \(error)")
    }
  }

  @Test func includeConfinedToPartialsStillWorksUntrusted() throws {
    let fixture = Fixture()
    fixture.writePartial("from the partial", named: "header.md")
    let engine = fixture.makeEngine()

    let rendered = try engine.render(
      "{% include \"header.md\" %}", context: TemplateContext(), trust: .untrusted)

    #expect(rendered == "from the partial")
  }

  @Test func maliciousPartialWithADisallowedTagIsRejectedEvenWhenTheTopLevelTemplateIsClean() {
    let fixture = Fixture()
    fixture.writePartial("{% now %}", named: "malicious.md")
    let engine = fixture.makeEngine()

    do {
      _ = try engine.render(
        "clean top level: {% include \"malicious.md\" %}",
        context: TemplateContext(), trust: .untrusted)
      Issue.record("expected TemplateEngineError to be thrown")
    } catch let error as TemplateEngineError {
      #expect("\(error)".contains("now"))
    } catch {
      Issue.record("expected TemplateEngineError, got \(error)")
    }
  }

  // MARK: - Include-depth limit

  @Test func selfIncludingPartialTerminatesWithADescriptiveErrorInsteadOfHanging() {
    let fixture = Fixture()
    fixture.writePartial("before{% include \"loop.md\" %}after", named: "loop.md")
    let engine = fixture.makeEngine()

    do {
      let rendered = try engine.render(
        "{% include \"loop.md\" %}", context: TemplateContext(), trust: .untrusted)
      Issue.record("expected a throw, got \(rendered)")
    } catch let error as TemplateEngineError {
      #expect("\(error)".contains("depth"))
    } catch {
      Issue.record("expected TemplateEngineError, got \(error)")
    }
  }

  @Test func mutuallyIncludingPartialsTerminateWithADescriptiveErrorInsteadOfHanging() {
    let fixture = Fixture()
    fixture.writePartial("{% include \"b.md\" %}", named: "a.md")
    fixture.writePartial("{% include \"a.md\" %}", named: "b.md")
    let engine = fixture.makeEngine()

    do {
      let rendered = try engine.render(
        "{% include \"a.md\" %}", context: TemplateContext(), trust: .untrusted)
      Issue.record("expected a throw, got \(rendered)")
    } catch let error as TemplateEngineError {
      #expect("\(error)".contains("depth"))
    } catch {
      Issue.record("expected TemplateEngineError, got \(error)")
    }
  }

  // MARK: - Output-size limit

  @Test func hugeLiteralForLoopRangeIsRejectedBeforeRenderingEvenStarts() {
    let engine = Fixture().makeEngine()
    // A literal range wider than the output-size limit is rejected by
    // the fast syntactic check, before any Stencil rendering begins —
    // an attacker who fully controls the template text cannot make
    // this "run for a while and then fail"; it fails immediately.
    let template = "{% for i in 1...2000000 %}x{% endfor %}"

    do {
      let rendered = try engine.render(template, context: TemplateContext(), trust: .untrusted)
      Issue.record("expected a throw, got \(rendered.count) rendered characters")
    } catch let error as TemplateEngineError {
      #expect("\(error)".contains("output size") || "\(error)".contains("bytes"))
    } catch {
      Issue.record("expected TemplateEngineError, got \(error)")
    }
  }

  @Test func aForLoopRangeNearIntMaxIsRejectedWithoutCrashing() {
    let engine = Fixture().makeEngine()
    // Regression test: an earlier implementation computed the range's
    // span with plain `Int` subtraction, which traps (crashes the
    // process) for bounds this far apart, instead of throwing. Bounds
    // are literal `Int` extremes an attacker who controls the template
    // text can write directly.
    let template = "{% for i in 0...9223372036854775807 %}x{% endfor %}"

    do {
      let rendered = try engine.render(template, context: TemplateContext(), trust: .untrusted)
      Issue.record("expected a throw, got \(rendered.count) rendered characters")
    } catch let error as TemplateEngineError {
      #expect("\(error)".contains("output size") || "\(error)".contains("bytes"))
    } catch {
      Issue.record("expected TemplateEngineError, got \(error)")
    }
  }

  @Test func aForLoopRangeSpanningIntMinToIntMaxIsRejectedWithoutCrashing() {
    let engine = Fixture().makeEngine()
    let template = "{% for i in -9223372036854775808...9223372036854775807 %}x{% endfor %}"

    do {
      let rendered = try engine.render(template, context: TemplateContext(), trust: .untrusted)
      Issue.record("expected a throw, got \(rendered.count) rendered characters")
    } catch let error as TemplateEngineError {
      #expect("\(error)".contains("output size") || "\(error)".contains("bytes"))
    } catch {
      Issue.record("expected TemplateEngineError, got \(error)")
    }
  }

  @Test func manySiblingIncludesEachUnderTheLimitAreRejectedOnceTheirSumExceedsIt() {
    let fixture = Fixture()
    // Each include renders comfortably under the 1 MiB limit on its
    // own; only their sum (driven by the surrounding `{% for %}`)
    // exceeds it. This must be caught incrementally by the shared
    // `OutputSizeBudget`, not only by the whole-render backstop — a
    // regression test for the amplification gap a per-include check
    // alone (without the shared running total) would miss.
    let chunk = String(repeating: "x", count: 60_000)
    fixture.writePartial(chunk, named: "chunk.md")
    let engine = fixture.makeEngine()
    var context = TemplateContext()
    context.set(key: "iterations", to: .array(Array(repeating: .string(""), count: 30)))
    let template = "{% for i in iterations %}{% include \"chunk.md\" %}{% endfor %}"

    do {
      let rendered = try engine.render(template, context: context, trust: .untrusted)
      Issue.record("expected a throw, got \(rendered.count) rendered characters")
    } catch let error as TemplateEngineError {
      #expect("\(error)".contains("output size") || "\(error)".contains("bytes"))
    } catch {
      Issue.record("expected TemplateEngineError, got \(error)")
    }
  }

  @Test func outputSizeBudgetStopsLoadingFurtherIncludesOnceTheRunningTotalExceedsTheLimit() throws
  {
    // White-box regression test, driving `RestrictedIncludeExtension`/
    // `RestrictedIncludeNode` directly (bypassing `TemplateEngine`) so
    // it can *count* how many times the loop's `{% include %}` actually
    // resolved a template. `manySiblingIncludesEachUnderTheLimitAreRejectedOnceTheirSumExceedsIt`
    // above only proves eventual rejection — which the pre-existing
    // whole-render backstop alone would already provide for that exact
    // scenario — so it does not, by itself, prove the `OutputSizeBudget`
    // is what stopped things early rather than the backstop catching it
    // after all 30 iterations ran. This test proves the early-bailout
    // property directly: without the per-include budget check, every
    // one of the 30 iterations would call `loadTemplate` before the
    // whole-render backstop ever got a chance to fire.
    final class CountingLoader: Loader {
      let content: String
      private(set) var loadCount = 0

      init(content: String) { self.content = content }

      func loadTemplate(name: String, environment: Environment) throws -> Template {
        loadCount += 1
        return environment.templateClass.init(
          templateString: content, environment: environment, name: name)
      }
    }

    let chunk = String(repeating: "x", count: 60_000)
    let loader = CountingLoader(content: chunk)
    let environment = Environment(loader: loader, extensions: [RestrictedTagsExtension()])
    var dictionary: [String: Any] = ["iterations": Array(repeating: "", count: 30)]
    dictionary[RestrictedIncludeNode.sizeBudgetContextKey] = OutputSizeBudget()

    #expect(throws: (any Error).self) {
      _ = try environment.renderTemplate(
        string: "{% for i in iterations %}{% include \"chunk.md\" %}{% endfor %}",
        context: dictionary)
    }

    // 1 MiB / 60,000 bytes ≈ 18 includes before the budget trips;
    // asserting strictly fewer than all 30 proves the loop was cut
    // short, not merely that the final result was eventually rejected.
    #expect(loader.loadCount < 30)
  }

  @Test
  func hugeForLoopOverAContextProvidedCollectionTerminatesWithADescriptiveErrorInsteadOfHanging() {
    let engine = Fixture().makeEngine()
    // The huge collection comes from `context`, not a template-text
    // literal, so the fast literal-range check does not apply; the
    // whole-render output-size backstop is what catches this one.
    // Few, large items keep the test itself fast.
    var context = TemplateContext()
    let chunk = String(repeating: "x", count: 60_000)
    context.set(key: "items", to: .array(Array(repeating: .string(chunk), count: 20)))
    let template = "{% for item in items %}{{ item }}{% endfor %}"

    do {
      let rendered = try engine.render(template, context: context, trust: .untrusted)
      Issue.record("expected a throw, got \(rendered.count) rendered characters")
    } catch let error as TemplateEngineError {
      #expect("\(error)".contains("output size") || "\(error)".contains("bytes"))
    } catch {
      Issue.record("expected TemplateEngineError, got \(error)")
    }
  }

  @Test func aForLoopWellUnderTheOutputSizeLimitRendersUntrusted() throws {
    let engine = Fixture().makeEngine()

    let rendered = try engine.render(
      "{% for i in 1...5 %}x{% endfor %}", context: TemplateContext(), trust: .untrusted)

    #expect(rendered == "xxxxx")
  }

  // MARK: - Whitelisted constructs work untrusted

  @Test func elifBranchWorksUntrusted() throws {
    let engine = Fixture().makeEngine()
    var context = TemplateContext()
    context.set(key: "which", to: .number(2))
    let template = "{% if which == 1 %}one{% elif which == 2 %}two{% else %}other{% endif %}"

    let rendered = try engine.render(template, context: context, trust: .untrusted)

    #expect(rendered == "two")
  }

  @Test func forEmptyBranchWorksUntrusted() throws {
    let engine = Fixture().makeEngine()
    var context = TemplateContext()
    context.set(key: "items", to: .array([]))
    let template = "{% for item in items %}{{ item }}{% empty %}nothing{% endfor %}"

    let rendered = try engine.render(template, context: context, trust: .untrusted)

    #expect(rendered == "nothing")
  }

  @Test func ifForIncludeAndVariableSubstitutionAllWorkTogetherUntrusted() throws {
    let fixture = Fixture()
    fixture.writePartial("[partial]", named: "footer.md")
    let engine = fixture.makeEngine()
    var context = TemplateContext()
    context.set(key: "name", to: .string("world"))
    context.set(key: "flag", to: .bool(true))
    context.set(key: "items", to: .array([.string("a"), .string("b"), .string("c")]))
    let template = """
      Hello {{ name }}!\
      {% if flag %}yes{% else %}no{% endif %}\
      {% for item in items %}{{ item }}{% endfor %}\
      {% include "footer.md" %}
      """

    let rendered = try engine.render(template, context: context, trust: .untrusted)

    #expect(rendered == "Hello world!yesabc[partial]")
  }

  // MARK: - Iteration budget

  @Test func nestedLiteralRangesAreRejectedOnceTotalIterationsExceedTheBudget() {
    let engine = Fixture().makeEngine()
    // Each literal range individually passes the pre-render span check
    // (1000 is far under the limit); only their *product* — which no
    // per-token check can see — explodes. The shared iteration budget
    // must stop the render mid-loop, promptly, instead of grinding
    // through a million-plus iterations (or, with one more nesting
    // level, effectively hanging the process).
    let template = "{% for i in 1...1000 %}{% for j in 1...1000 %}{% endfor %}{% endfor %}"

    do {
      let rendered = try engine.render(template, context: TemplateContext(), trust: .untrusted)
      Issue.record("expected a throw, got \(rendered.count) rendered characters")
    } catch let error as TemplateEngineError {
      #expect("\(error)".contains("iteration"))
    } catch {
      Issue.record("expected TemplateEngineError, got \(error)")
    }
  }

  @Test func anAllFilteringWhereClauseOverALargeRangeStillConsumesTheIterationBudget() {
    let engine = Fixture().makeEngine()
    // A `where` clause is evaluated per *candidate* value, before any
    // body renders — so a range that passes the pre-render span check
    // with a never-true `where` performs its full candidate count of
    // expression evaluations while producing zero output and zero
    // rendered iterations. The iteration budget must be debited per
    // candidate examined (pre-filter), or this is exactly the
    // no-output time bomb the budget exists to close, reachable
    // through `where` instead of an empty body.
    let template = "{% for i in 1...200000 where i > 300000 %}x{% endfor %}"

    do {
      let rendered = try engine.render(template, context: TemplateContext(), trust: .untrusted)
      Issue.record("expected a throw, got \(rendered.count) rendered characters")
    } catch let error as TemplateEngineError {
      #expect("\(error)".contains("iteration"))
    } catch {
      Issue.record("expected TemplateEngineError, got \(error)")
    }
  }

  @Test func nestedLoopBodiesConsumeTheSharedOutputBudgetMidRender() {
    let engine = Fixture().makeEngine()
    // 300 × 300 = 90,000 iterations — under the iteration budget — each
    // appending 16 bytes: ~1.4 MiB, over the output budget. Loop bodies
    // must consume the shared output budget as they render; metering
    // includes alone would let an include-free loop materialize an
    // arbitrarily large intermediate before the whole-render backstop
    // ever ran.
    let template =
      "{% for i in 1...300 %}{% for j in 1...300 %}0123456789abcdef{% endfor %}{% endfor %}"

    do {
      let rendered = try engine.render(template, context: TemplateContext(), trust: .untrusted)
      Issue.record("expected a throw, got \(rendered.count) rendered characters")
    } catch let error as TemplateEngineError {
      #expect("\(error)".contains("output size") || "\(error)".contains("bytes"))
    } catch {
      Issue.record("expected TemplateEngineError, got \(error)")
    }
  }

  @Test func aLoopBodyMixingIncludesAndLiteralsIsNotDoubleCounted() throws {
    let fixture = Fixture()
    // The include's bytes are consumed by `RestrictedIncludeNode` as it
    // renders; the enclosing loop must meter only the bytes *not*
    // already consumed by nested metered nodes. If it re-counted the
    // include's contribution, this comfortably-legal render (~720 KiB
    // actually produced) would falsely exceed the 1 MiB budget.
    let chunk = String(repeating: "x", count: 60_000)
    fixture.writePartial(chunk, named: "chunk.md")
    let engine = fixture.makeEngine()
    var context = TemplateContext()
    context.set(key: "iterations", to: .array(Array(repeating: .string(""), count: 12)))
    let template = "{% for i in iterations %}{% include \"chunk.md\" %}y{% endfor %}"

    let rendered = try engine.render(template, context: context, trust: .untrusted)

    #expect(rendered.utf8.count == 12 * (60_000 + 1))
  }

  // MARK: - Restricted for-loop parity with Stencil's own

  @Test func forloopMetaVariablesRenderUntrusted() throws {
    let engine = Fixture().makeEngine()

    let rendered = try engine.render(
      "{% for i in 1...3 %}{{ forloop.counter }}:{{ forloop.first }}:{{ forloop.last }} {% endfor %}",
      context: TemplateContext(), trust: .untrusted)

    #expect(rendered == "1:true:false 2:false:false 3:false:true ")
  }

  @Test func aWhereClauseFiltersUntrustedLoopIterations() throws {
    let engine = Fixture().makeEngine()
    var context = TemplateContext()
    context.set(
      key: "items", to: .array([.string("a"), .string("skip"), .string("b")]))

    let rendered = try engine.render(
      "{% for item in items where item != \"skip\" %}{{ item }}{% endfor %}",
      context: context, trust: .untrusted)

    #expect(rendered == "ab")
  }

  @Test func dictionaryIterationWithTupleUnpackingRendersUntrusted() throws {
    let engine = Fixture().makeEngine()
    var context = TemplateContext()
    context.set(
      key: "settings",
      to: .dictionary(["b": .string("2"), "a": .string("1")]))

    let rendered = try engine.render(
      "{% for key, value in settings %}{{ key }}={{ value }};{% endfor %}",
      context: context, trust: .untrusted)

    #expect(rendered == "a=1;b=2;")
  }
}
