import ArgumentParser
import Foundation
import FoundationModelsExtras

/// `extras-demo render <file>` — pillar 3 (plan.md §7): renders a
/// frontmatter+markdown template through `TemplateEngine`, showing a
/// `--set` context variable, an environment variable, a well-known value,
/// and a `{% include "header.md" %}` partial resolved from the fixture's
/// layered `_partials/` (the project fixture shadows the user one).
/// `--untrusted` renders the same file under `Trust.untrusted` instead of
/// `Trust.trusted`, demonstrating the trust split: a deliberately bad
/// fixture (`Fixtures/render/bad.md`) renders trusted but is rejected
/// untrusted.
struct RenderCommand: AsyncParsableCommand {
    /// This subcommand's command-line configuration.
    static let configuration = CommandConfiguration(
        commandName: "render",
        abstract: "Renders a frontmatter+markdown template through TemplateEngine."
    )

    /// The template file to render.
    @Argument(help: "Path to the template file to render.")
    var file: String

    /// `key=value` context entries, one `TemplateContext` value per entry.
    /// May be repeated.
    @Option(name: .customLong("set"), help: "A context variable, key=value. May be repeated.")
    var sets: [String] = []

    /// Renders under `Trust.untrusted` instead of `Trust.trusted`.
    @Flag(name: .customLong("untrusted"), help: "Render under Trust.untrusted instead of Trust.trusted.")
    var untrusted = false

    /// Reads `file`, renders it through `TemplateEngine`, and prints its
    /// frontmatter (if any) and body.
    func run() throws {
        let rawText: String
        do {
            rawText = try String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("render failed: could not read '\(file)': \(error)\n".utf8))
            throw ExitCode.failure
        }

        var context = TemplateContext()
        for entry in sets {
            guard let separator = entry.firstIndex(of: "=") else {
                throw ValidationError("--set expects key=value, got '\(entry)'")
            }
            context.set(
                key: String(entry[entry.startIndex..<separator]),
                to: .string(String(entry[entry.index(after: separator)...])))
        }

        let engine = TemplateEngine(partials: DemoFixtures.makeStack())
        let trust: TemplateEngine.Trust = untrusted ? .untrusted : .trusted

        let rendered: String
        do {
            rendered = try engine.render(rawText, context: context, trust: trust)
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            throw ExitCode.failure
        }

        let (frontmatter, body) = FrontmatterDocument.split(text: rendered)
        if let frontmatter {
            print("frontmatter:")
            print(frontmatter)
        }
        print("body:")
        print(body)
    }
}
