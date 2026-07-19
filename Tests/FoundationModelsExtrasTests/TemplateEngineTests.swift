import Foundation
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `TemplateEngine`: trusted rendering of the Stencil
/// syntax slice plan.md §4 targets (`{{ var }}`, `{% if %}`, `{% for %}`),
/// the three-rung variable precedence ladder, well-known variables, facade
/// error surfacing, and the whole-file render-then-split round trip.
/// `Trust.untrusted`'s whitelist, limits, and loader confinement have their
/// own dedicated suite in `UntrustedRenderingTests.swift`.
@Suite struct TemplateEngineTests {
    /// Deterministic well-known values so tests never depend on real
    /// process state (current directory, real date, real hostname).
    private static let fixtureWellKnownValues = WellKnownValues(
        workingDirectory: "/fixture/cwd",
        date: "2020-01-01",
        hostname: "fixture-host",
        dotfolderName: nil
    )

    /// An engine wired through the hermetic-test seam: an explicit
    /// environment dictionary and well-known values, defaulting to values
    /// that never collide with the tests' own precedence-ladder keys.
    private static func makeEngine(
        partials: DotfolderStack? = nil,
        environment: [String: String] = [:],
        wellKnownValues: WellKnownValues = fixtureWellKnownValues
    ) -> TemplateEngine {
        TemplateEngine(partials: partials, environment: environment, wellKnownValues: wellKnownValues)
    }

    @Test func rendersASimpleVariableSubstitution() throws {
        let engine = Self.makeEngine()
        var context = TemplateContext()
        context.set(key: "name", to: .string("world"))

        let rendered = try engine.render("Hello {{ name }}!", context: context, trust: .trusted)

        #expect(rendered == "Hello world!")
    }

    @Test func rendersAnIfTagByTruthiness() throws {
        let engine = Self.makeEngine()
        var trueContext = TemplateContext()
        trueContext.set(key: "flag", to: .bool(true))
        var falseContext = TemplateContext()
        falseContext.set(key: "flag", to: .bool(false))
        let template = "{% if flag %}yes{% else %}no{% endif %}"

        #expect(try engine.render(template, context: trueContext, trust: .trusted) == "yes")
        #expect(try engine.render(template, context: falseContext, trust: .trusted) == "no")
    }

    @Test func rendersAForTagOverAnArrayContextValue() throws {
        let engine = Self.makeEngine()
        var context = TemplateContext()
        context.set(key: "items", to: .array([.string("a"), .string("b"), .string("c")]))

        let rendered = try engine.render(
            "{% for item in items %}{{ item }}{% endfor %}", context: context, trust: .trusted)

        #expect(rendered == "abc")
    }

    @Test func explicitContextValueBeatsEnvironmentVariableBeatsWellKnownValueForTheSameKey() throws {
        // All three rungs define "hostname" so the assertion actually
        // exercises context beating environment (not just context beating
        // well-known, which a same-key env value could otherwise mask).
        let engine = Self.makeEngine(
            environment: ["hostname": "from-env"],
            wellKnownValues: WellKnownValues(
                workingDirectory: "/fixture/cwd",
                date: "2020-01-01",
                hostname: "from-well-known",
                dotfolderName: nil
            )
        )
        var context = TemplateContext()
        context.set(key: "hostname", to: .string("from-context"))

        let rendered = try engine.render("{{ hostname }}", context: context, trust: .trusted)

        #expect(rendered == "from-context")
    }

    @Test func environmentVariableBeatsWellKnownValueWhenContextDoesNotOverrideTheSameKey() throws {
        let engine = Self.makeEngine(
            environment: ["hostname": "from-env"],
            wellKnownValues: WellKnownValues(
                workingDirectory: "/fixture/cwd",
                date: "2020-01-01",
                hostname: "from-well-known",
                dotfolderName: nil
            )
        )

        let rendered = try engine.render("{{ hostname }}", context: TemplateContext(), trust: .trusted)

        #expect(rendered == "from-env")
    }

    @Test func wellKnownValuesArePresentWhenNothingOverridesThem() throws {
        let engine = Self.makeEngine()

        let rendered = try engine.render(
            "{{ working_directory }}|{{ date }}|{{ hostname }}",
            context: TemplateContext(),
            trust: .trusted
        )

        #expect(rendered == "/fixture/cwd|2020-01-01|fixture-host")
    }

    @Test func dotfolderNameWellKnownValueIsPresentWhenAStackWasGiven() throws {
        let stack = DotfolderStack(
            name: "testagent",
            workingDirectory: URL(fileURLWithPath: "/fixture/workspace"),
            userDirectory: URL(fileURLWithPath: "/fixture/home/.testagent")
        )
        let engine = TemplateEngine(
            partials: stack, environment: [:], wellKnownValues: .current(partials: stack))

        let rendered = try engine.render(
            "{{ dotfolder_name }}", context: TemplateContext(), trust: .trusted)

        #expect(rendered == "testagent")
    }

    @Test func dotfolderNameWellKnownValueIsAbsentWhenNoStackWasGiven() throws {
        let engine = TemplateEngine(partials: nil, environment: [:], wellKnownValues: .current(partials: nil))

        let rendered = try engine.render(
            "{{ dotfolder_name|default:\"missing\" }}", context: TemplateContext(), trust: .trusted)

        #expect(rendered == "missing")
    }

    @Test func malformedTemplateThrowsTheFacadeErrorTypeWithAUsefulMessage() {
        let engine = Self.makeEngine()

        do {
            _ = try engine.render(
                "{% if flag %}unterminated", context: TemplateContext(), trust: .trusted)
            Issue.record("expected TemplateEngineError to be thrown")
        } catch let error as TemplateEngineError {
            #expect("\(error)".contains("endif"))
        } catch {
            Issue.record("expected TemplateEngineError, got \(error)")
        }
    }

    @Test func untrustedRenderingOfAWhitelistedTemplateSucceeds() throws {
        let engine = Self.makeEngine()
        var context = TemplateContext()
        context.set(key: "name", to: .string("world"))

        let rendered = try engine.render("Hello {{ name }}!", context: context, trust: .untrusted)

        #expect(rendered == "Hello world!")
    }

    @Test func rendersAFrontmatterDocumentThenSplitsItRoundTrip() throws {
        let engine = Self.makeEngine()
        var context = TemplateContext()
        context.set(key: "title", to: .string("Weekly Report"))
        let document = """
            ---
            title: {{ title }}
            ---
            # {{ title }}

            Body text.
            """

        let rendered = try engine.render(document, context: context, trust: .trusted)
        let (frontmatter, body) = FrontmatterDocument.split(text: rendered)

        #expect(frontmatter == "title: Weekly Report\n")
        #expect(body == "# Weekly Report\n\nBody text.")
    }
}
