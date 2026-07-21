import ArgumentParser
import Foundation
import FoundationModelsExtras

/// `extras-demo config` — pillar 5 (plan.md §11): loads the fixture
/// `config.yaml` across the demo's layered stack with
/// `LayeredYAMLDocument.load`, printing the merged tree annotated per key
/// with the winning layer — the source-tracking story made visible, same
/// spirit as `extras-demo stack`.
struct ConfigCommand: AsyncParsableCommand {
    /// This subcommand's command-line configuration.
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract:
            "Loads config.yaml across the fixture stack and prints the merged tree annotated with winning layers."
    )

    /// The config file resolved and reported by this command, relative to a
    /// layer's root.
    private static let configFileName = "config.yaml"

    /// Loads `config.yaml` across the demo stack, rendering every layer
    /// (the `user` layer's `token` value is templated: `{{ HOME }}`,
    /// proving templated values resolve per layer before the merge), then
    /// prints one line per merged leaf key path with its value and the
    /// winning layer.
    func run() throws {
        let stack = DemoFixtures.makeStack()
        let engine = TemplateEngine(partials: stack)

        let document: LayeredYAMLDocument
        do {
            document = try LayeredYAMLDocument.load(
                Self.configFileName, from: stack, engine: engine, context: TemplateContext())
        } catch {
            FileHandle.standardError.write(Data("config failed: \(error)\n".utf8))
            throw ExitCode.failure
        }

        guard case .dictionary = document.root else {
            print("\(Self.configFileName) -> not found")
            return
        }

        for line in Self.lines(for: document.root, keyPath: [], document: document) {
            print(line)
        }
    }

    /// Recursively renders `value` into `"key.path: value ← layer"` lines,
    /// one per merged leaf (scalar or array) — dictionaries have no line of
    /// their own, only their entries do, sorted by key at every level for
    /// deterministic output.
    private static func lines(
        for value: YAMLValue, keyPath: [String], document: LayeredYAMLDocument
    ) -> [String] {
        guard case .dictionary(let dictionary) = value else {
            let path = keyPath.joined(separator: ".")
            let source = document.source(of: keyPath).map(Self.label(for:)) ?? "unknown"
            return ["\(path): \(describe(value)) ← \(source)"]
        }
        return dictionary.keys.sorted().flatMap { key in
            // Safe to force-unwrap: `key` is drawn from `dictionary`'s own keys.
            lines(for: dictionary[key]!, keyPath: keyPath + [key], document: document)
        }
    }

    /// A compact textual rendering of a leaf `YAMLValue` for this command's
    /// output — not a general-purpose `YAMLValue` formatter, just enough to
    /// make the demo's merged tree readable.
    private static func describe(_ value: YAMLValue) -> String {
        switch value {
        case .string(let string):
            return string
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .bool(let bool):
            return String(bool)
        case .null:
            return "null"
        case .array(let values):
            return "[" + values.map(describe).joined(separator: ", ") + "]"
        case .dictionary:
            return "{...}"
        }
    }

    /// Short labels for each `DotfolderStack.Source`, matching this
    /// command's output format — a data table instead of parallel
    /// switch-case branches, mirroring `StackCommand`'s own `sourceLabels`.
    private static let sourceLabels: [DotfolderStack.Source: String] = [
        .defaults: "defaults",
        .user: "user",
        .project: "project",
    ]

    /// A short label for `source`, matching this command's output format.
    private static func label(for source: DotfolderStack.Source) -> String {
        sourceLabels[source] ?? "unknown"
    }
}
