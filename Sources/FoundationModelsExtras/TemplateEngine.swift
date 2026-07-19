import Foundation
import Stencil

/// Errors thrown by `TemplateEngine.render` — the package's own error type;
/// no Stencil type ever crosses this boundary (plan.md §4).
public enum TemplateEngineError: Error, Sendable, CustomStringConvertible {
    /// Stencil failed to parse or render the template. `message` carries
    /// Stencil's own diagnostic text (location, reason) so consumers get a
    /// useful message, with no Stencil type retained.
    case renderingFailed(message: String)
    /// `Trust.untrusted` rendering is not implemented yet: the restricted
    /// `Environment` (whitelisted tags/filters, a loader confined to
    /// `_partials/`, include-depth and output-size limits) is a follow-up
    /// task (plan.md §4). Requesting it today throws rather than silently
    /// falling back to the unrestricted trusted path.
    case untrustedRenderingNotYetImplemented

    /// A human-readable description of the failure.
    public var description: String {
        switch self {
        case .renderingFailed(let message):
            return "template rendering failed: \(message)"
        case .untrustedRenderingNotYetImplemented:
            return "untrusted template rendering is not yet implemented"
        }
    }
}

/// The Stencil wrap every dotfolder document renders through (plan.md §4):
/// consumers never see a Stencil or PathKit type, only this facade, plain
/// `String`s, and `TemplateContext`. Implements the `trusted` path with
/// `{% include %}` partial resolution through `partials`, when given, via
/// `DotfolderLoader`; `Trust.untrusted` is accepted but its restricted
/// `Environment` lands in a follow-up task.
public struct TemplateEngine: Sendable {
    /// Which validation path `render` takes.
    public enum Trust: Sendable {
        /// Consumer-shipped defaults: full Stencil, no restrictions. The
        /// only path implemented today.
        case trusted
        /// User/project-layer files: a restricted `Environment` is planned
        /// (plan.md §4) but not implemented yet — `render` throws
        /// `TemplateEngineError.untrustedRenderingNotYetImplemented`.
        case untrusted
    }

    /// The partials stack passed at construction. When non-`nil`, backs a
    /// `DotfolderLoader` that resolves `{% include %}` through its layered
    /// `_partials/` directories (plan.md §4); also consulted here for the
    /// well-known `dotfolder_name` variable, present only when a stack was
    /// given.
    private let partials: DotfolderStack?

    /// The environment dictionary consulted for the precedence ladder's
    /// middle rung.
    private let environment: [String: String]

    /// The well-known system variables backing the ladder's lowest rung.
    private let wellKnownValues: WellKnownValues

    /// Creates an engine. `partials`, when given, backs the `DotfolderLoader`
    /// that resolves `{% include %}` through its layered `_partials/`
    /// directories, and makes its dotfolder name available as the
    /// well-known `dotfolder_name` variable (plan.md §4).
    public init(partials: DotfolderStack?) {
        self.init(
            partials: partials,
            environment: ProcessInfo.processInfo.environment,
            wellKnownValues: .current(partials: partials)
        )
    }

    /// Hermetic-test seam: overrides the environment dictionary and
    /// well-known values the public initializer otherwise derives from real
    /// process state, so precedence-ladder tests are deterministic. Not
    /// part of the public surface — plan.md §4 specifies only
    /// `init(partials:)`.
    init(
        partials: DotfolderStack?,
        environment: [String: String],
        wellKnownValues: WellKnownValues
    ) {
        self.partials = partials
        self.environment = environment
        self.wellKnownValues = wellKnownValues
    }

    /// Renders `text` as a Stencil template against `context`, with
    /// variables resolved through the three-rung precedence ladder
    /// (plan.md §4): `context` beats this engine's environment dictionary
    /// beats its well-known values.
    ///
    /// - Parameters:
    ///   - text: The raw template text — a whole dotfolder document,
    ///     frontmatter included, rendered before `FrontmatterDocument.split`
    ///     ever sees it (plan.md §4's whole-file-render-then-parse rule).
    ///   - context: Explicit values, the ladder's highest rung.
    ///   - trust: `.trusted` for consumer-shipped defaults, the only path
    ///     implemented today; `.untrusted` throws
    ///     `TemplateEngineError.untrustedRenderingNotYetImplemented`.
    /// - Returns: The rendered text.
    /// - Throws: `TemplateEngineError.untrustedRenderingNotYetImplemented`
    ///   for `trust: .untrusted`; `TemplateEngineError.renderingFailed` when
    ///   Stencil fails to parse or render `text`.
    public func render(_ text: String, context: TemplateContext, trust: Trust) throws -> String {
        switch trust {
        case .untrusted:
            throw TemplateEngineError.untrustedRenderingNotYetImplemented
        case .trusted:
            let stencilEnvironment =
                partials.map { Environment(loader: DotfolderLoader(stack: $0)) } ?? Environment()
            do {
                return try stencilEnvironment.renderTemplate(
                    string: text, context: mergedDictionary(explicit: context))
            } catch {
                throw TemplateEngineError.renderingFailed(message: String(describing: error))
            }
        }
    }

    /// Builds the `[String: Any]` dictionary Stencil consumes: well-known
    /// values lowest, this engine's environment dictionary next, `explicit`
    /// highest — built lowest-first and overlaid upward, per plan.md §4's
    /// precedence ladder.
    private func mergedDictionary(explicit context: TemplateContext) -> [String: Any] {
        let wellKnownContext = buildContext(from: wellKnownValues.templateValues)
        let environmentContext = buildContext(from: environment.mapValues { .string($0) })

        return
            wellKnownContext
            .stencilDictionary()
            .merging(environmentContext.stencilDictionary()) { _, higherRung in higherRung }
            .merging(context.stencilDictionary()) { _, higherRung in higherRung }
    }

    /// Builds a `TemplateContext` from a `[String: TemplateValue]` dictionary
    /// by setting each key/value pair — the shared step both the well-known
    /// and environment rungs of the precedence ladder need before they can be
    /// merged (plan.md §4).
    private func buildContext(from values: [String: TemplateValue]) -> TemplateContext {
        var context = TemplateContext()
        for (key, value) in values {
            context.set(key: key, to: value)
        }
        return context
    }
}

/// The well-known system variables backing the precedence ladder's lowest
/// rung (plan.md §4): dotfolder name (present only when a `partials` stack
/// was given), working directory, date, and hostname. Plain injectable data
/// — `current(partials:)` derives the real values `TemplateEngine`'s public
/// `init(partials:)` uses; tests inject fixed values directly so the ladder
/// is deterministic.
struct WellKnownValues: Sendable {
    /// The current working directory.
    var workingDirectory: String
    /// Today's date.
    var date: String
    /// The current machine's hostname.
    var hostname: String
    /// The dotfolder name recovered from a `partials` stack's project
    /// layer, or `nil` when no stack was given.
    var dotfolderName: String?

    /// This value's fields as `TemplateValue`s, keyed ready to overlay into
    /// a `TemplateContext`. `dotfolder_name` is present only when
    /// `dotfolderName` is non-`nil`.
    var templateValues: [String: TemplateValue] {
        var values: [String: TemplateValue] = [
            "working_directory": .string(workingDirectory),
            "date": .string(date),
            "hostname": .string(hostname),
        ]
        if let dotfolderName {
            values["dotfolder_name"] = .string(dotfolderName)
        }
        return values
    }

    /// Formats `date` as a bare calendar date fixed to UTC, so the string
    /// does not depend on the running machine's local time zone.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Derives the real well-known values from process state: the current
    /// working directory, today's UTC date, this machine's hostname, and
    /// (when `partials` is non-`nil`) its project layer's dotfolder name.
    static func current(partials: DotfolderStack?) -> WellKnownValues {
        WellKnownValues(
            workingDirectory: FileManager.default.currentDirectoryPath,
            date: dateFormatter.string(from: Date()),
            hostname: ProcessInfo.processInfo.hostName,
            dotfolderName: partials?.projectDotfolderName
        )
    }
}

extension DotfolderStack {
    /// Recovers this stack's bare dotfolder name (e.g. `"myagent"`) from its
    /// project layer's root directory name (`<workingDirectory>/.myagent`)
    /// — the one layer `DotfolderStack.init` always appends regardless of
    /// whether `defaultsDirectory`/`userDirectory` were supplied, so this
    /// never returns `nil` for a real stack.
    fileprivate var projectDotfolderName: String? {
        guard let projectLayer = layers.first(where: { $0.source == .project }) else { return nil }
        let directoryName = projectLayer.root.lastPathComponent
        return directoryName.hasPrefix(".") ? String(directoryName.dropFirst()) : directoryName
    }
}
