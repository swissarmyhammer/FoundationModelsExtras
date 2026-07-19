import Foundation
import Stencil

/// Errors thrown by `TemplateEngine.render` — the package's own error type;
/// no Stencil type ever crosses this boundary (plan.md §4).
public enum TemplateEngineError: Error, Sendable, CustomStringConvertible {
    /// Stencil failed to parse or render the template, or `Trust.untrusted`
    /// validation rejected it before or during rendering — a disallowed
    /// tag/filter, an include-depth bomb, or an output-size bomb (plan.md
    /// §4). `message` carries the underlying diagnostic text (Stencil's own
    /// location/reason, or this package's own untrusted-validation
    /// description) so consumers get a useful message, with no Stencil (or
    /// other internal) type retained.
    case renderingFailed(message: String)

    /// A human-readable description of the failure.
    public var description: String {
        switch self {
        case .renderingFailed(let message):
            return "template rendering failed: \(message)"
        }
    }
}

/// `Trust.untrusted`'s own validation and enforcement failures — thrown from
/// within `TemplateEngine`'s untrusted path (directly by
/// `TemplateEngine.validateUntrustedSyntax`/`validateUntrustedTokens`, or by
/// `RestrictedIncludeNode` during rendering) and never surfaced directly (it
/// is not `public`): a failure raised *during* rendering passes through
/// Stencil's own node-rendering machinery on its way out, which re-wraps any
/// non-`TemplateSyntaxError` in a `TemplateSyntaxError` carrying this error's
/// `description` as its reason — the text survives, only the type is
/// replaced. Either way, `TemplateEngine.render`'s catch-all re-describes the
/// failure inside `TemplateEngineError.renderingFailed`, mirroring how
/// `DotfolderLoaderError` never crosses the facade either (plan.md §4).
enum UntrustedTemplateError: Error, Sendable, CustomStringConvertible {
    /// The template used a tag not in `TemplateEngine.untrustedAllowedTags`.
    case tagNotAllowed(tag: String)
    /// The template used a filter not in
    /// `TemplateEngine.untrustedAllowedFilters` (which starts empty).
    case filterNotAllowed(filter: String)
    /// `{% include %}` nesting exceeded
    /// `TemplateEngine.untrustedIncludeDepthLimit`.
    case includeDepthExceeded(limit: Int)
    /// The rendered output exceeded
    /// `TemplateEngine.untrustedOutputSizeLimit` bytes.
    case outputTooLarge(limit: Int)

    /// A human-readable description naming the rejected construct or
    /// exceeded limit.
    var description: String {
        switch self {
        case .tagNotAllowed(let tag):
            return "untrusted rendering does not allow the '\(tag)' tag"
        case .filterNotAllowed(let filter):
            return "untrusted rendering does not allow the '\(filter)' filter"
        case .includeDepthExceeded(let limit):
            return "untrusted rendering exceeded the maximum include depth (\(limit))"
        case .outputTooLarge(let limit):
            return "untrusted rendering exceeded the maximum output size (\(limit) bytes)"
        }
    }
}

/// The Stencil wrap every dotfolder document renders through (plan.md §4):
/// consumers never see a Stencil or PathKit type, only this facade, plain
/// `String`s, and `TemplateContext`. Implements both the `trusted` path
/// (full Stencil, no restrictions) and the `untrusted` path (a whitelisted
/// tag/filter set, an `{% include %}` depth limit, and an output-size
/// limit); `{% include %}` partial resolution through `partials`, when
/// given, goes through `DotfolderLoader` on both paths.
public struct TemplateEngine: Sendable {
    /// Which validation path `render` takes.
    public enum Trust: Sendable {
        /// Consumer-shipped defaults: full Stencil, no restrictions.
        case trusted
        /// User/project-layer files: a restricted `Environment` (plan.md
        /// §4). Stencil has no filesystem/network/exec capability of its
        /// own, so this restriction *is* the whole enforcement surface:
        ///
        /// - **Tag whitelist** — `TemplateEngine.untrustedAllowedTags`
        ///   (`if`/`for`/`include`, plus the branch and closing keywords
        ///   those two need: `elif`/`else`/`endif`,
        ///   `empty`/`endfor`). Any other tag — including Stencil's own
        ///   `extends`, `block`, `filter`, `now`, `break`, `continue`, and
        ///   `ifnot` — is rejected before any rendering begins, even inside
        ///   a branch that would not otherwise execute.
        /// - **Filter whitelist** — `TemplateEngine.untrustedAllowedFilters`,
        ///   which starts *empty*: the swissarmyhammer corpus this package
        ///   ports (plan.md §4) uses zero filters. Any filter use is
        ///   rejected the same way.
        /// - **Loader confined to `_partials/`** — `{% include %}` only
        ///   ever resolves through `DotfolderLoader`'s `_partials/`
        ///   name-resolution scheme; an absolute path or a name containing
        ///   a `..` traversal component never resolves to a file (enforced
        ///   by `DotfolderStack`'s own path-safety check, which every
        ///   lookup routes through regardless of trust).
        /// - **Include-depth limit** —
        ///   `TemplateEngine.untrustedIncludeDepthLimit` (8): a self- or
        ///   mutually including partial cannot recurse without bound.
        ///   Every partial loaded through `{% include %}` is also
        ///   re-validated against the tag/filter whitelist, so a malicious
        ///   partial cannot smuggle in a disallowed construct just because
        ///   the top-level template that includes it was clean.
        /// - **Output-size limit** —
        ///   `TemplateEngine.untrustedOutputSizeLimit` (1 MiB): guards
        ///   against an output-size bomb, e.g. a `{% for %}` over a huge
        ///   collection.
        ///
        /// Env vars remain *values in the context*, not an exec capability
        /// — nothing about the precedence ladder changes between trust
        /// modes.
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
    ///   - trust: `.trusted` for consumer-shipped defaults: full Stencil, no
    ///     restrictions. `.untrusted` for user/project-layer files: validated
    ///     against the whitelist and limits documented on `Trust.untrusted`
    ///     before and during rendering.
    /// - Returns: The rendered text.
    /// - Throws: `TemplateEngineError.renderingFailed` when Stencil fails to
    ///   parse or render `text`, or when `trust: .untrusted` validation
    ///   rejects it (a disallowed tag/filter, an include-depth bomb, or an
    ///   output-size bomb).
    public func render(_ text: String, context: TemplateContext, trust: Trust) throws -> String {
        do {
            switch trust {
            case .trusted:
                let stencilEnvironment =
                    partials.map { Environment(loader: DotfolderLoader(stack: $0)) } ?? Environment()
                return try stencilEnvironment.renderTemplate(
                    string: text, context: mergedDictionary(explicit: context))
            case .untrusted:
                try Self.validateUntrustedSyntax(text)
                let stencilEnvironment = Environment(
                    loader: partials.map { DotfolderLoader(stack: $0) },
                    extensions: [RestrictedIncludeExtension()]
                )
                // The budget object is looked up by reference, not by
                // value, so every `RestrictedIncludeNode` — no matter how
                // deeply nested, or how many sibling includes a `{% for %}`
                // drives through the same tag — shares and mutates this
                // one instance, catching an amplification bomb (many
                // includes, each individually small) as soon as their
                // running total crosses the limit, rather than only after
                // the whole render finishes.
                var contextDictionary = mergedDictionary(explicit: context)
                let outputSizeBudget = OutputSizeBudget()
                contextDictionary[RestrictedIncludeNode.sizeBudgetContextKey] = outputSizeBudget
                let rendered = try stencilEnvironment.renderTemplate(
                    string: text, context: contextDictionary)
                guard rendered.utf8.count <= Self.untrustedOutputSizeLimit else {
                    throw UntrustedTemplateError.outputTooLarge(limit: Self.untrustedOutputSizeLimit)
                }
                return rendered
            }
        } catch {
            throw TemplateEngineError.renderingFailed(message: String(describing: error))
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

extension TemplateEngine {
    /// The Stencil tags `Trust.untrusted` permits: `if`/`for`/`include`,
    /// plus the branch and closing keywords those two control-flow tags
    /// need. Any other tag — including Stencil's own `extends`, `block`,
    /// `filter`, `now`, `break`, `continue`, and `ifnot` — fails validation
    /// before any rendering begins (plan.md §4).
    static let untrustedAllowedTags: Set<String> = [
        "if", "elif", "else", "endif",
        "for", "empty", "endfor",
        "include",
    ]

    /// The Stencil filters `Trust.untrusted` permits: none. The
    /// swissarmyhammer corpus this package ports (plan.md §4) survey found
    /// zero filters in use, so untrusted validation starts from the
    /// narrowest possible whitelist; widening it to cover a real consumer
    /// need is a one-line addition here.
    static let untrustedAllowedFilters: Set<String> = []

    /// The maximum `{% include %}` nesting depth `Trust.untrusted` permits
    /// before failing with a descriptive error — the untrusted path's
    /// defense against a self- or mutually including partial recursing
    /// without bound (plan.md §4).
    static let untrustedIncludeDepthLimit = 8

    /// The maximum size, in UTF-8 bytes, a `Trust.untrusted` render's
    /// output may reach before failing with a descriptive error — the
    /// untrusted path's defense against an output-size bomb, e.g. a
    /// `{% for %}` over a huge collection (plan.md §4).
    static let untrustedOutputSizeLimit = 1 << 20  // 1 MiB

    /// Rejects `text` under `Trust.untrusted`'s whitelist before any
    /// Stencil rendering begins. Lexes `text` the same way Stencil itself
    /// would (via a throwaway `Template`, whose tokenizing is independent
    /// of any `Environment`) and delegates to `validateUntrustedTokens`.
    ///
    /// - Throws: `UntrustedTemplateError.tagNotAllowed` or
    ///   `.filterNotAllowed`.
    static func validateUntrustedSyntax(_ text: String) throws {
        try validateUntrustedTokens(Template(templateString: text).tokens)
    }

    /// The token-level whitelist check both `validateUntrustedSyntax` and
    /// `RestrictedIncludeNode` (re-validating each loaded partial) call:
    /// walks `tokens` — the same lexed tokens Stencil itself would parse —
    /// checking every `{% %}` tag against `untrustedAllowedTags` and every
    /// `{{ ... | filter }}` filter against `untrustedAllowedFilters`. Runs
    /// over lexed tokens rather than parsed nodes, so a disallowed
    /// construct is caught even inside a branch that would not otherwise
    /// render (e.g. a `{% for %}` body that never executes) (plan.md §4).
    ///
    /// - Throws: `UntrustedTemplateError.tagNotAllowed` or
    ///   `.filterNotAllowed`.
    static func validateUntrustedTokens(_ tokens: [Token]) throws {
        for token in tokens {
            switch token.kind {
            case .block:
                let tag = tagName(from: token)
                guard untrustedAllowedTags.contains(tag) else {
                    throw UntrustedTemplateError.tagNotAllowed(tag: tag)
                }
                if tag == "for" {
                    try validateForLoopRange(token)
                }
            case .variable:
                for filter in filterNames(from: token) where !untrustedAllowedFilters.contains(filter) {
                    throw UntrustedTemplateError.filterNotAllowed(filter: filter)
                }
            case .text, .comment:
                continue
            }
        }
    }

    /// Rejects a `{% for %}` tag whose iterable is a *literal* integer range
    /// (`N...M`) wider than `untrustedOutputSizeLimit` — an attacker who
    /// controls the template text can otherwise manufacture an arbitrarily
    /// large iteration count with no data dependency at all (e.g.
    /// `{% for i in 1...999999999 %}`), which the whole-render output-size
    /// check alone would only catch *after* actually running the loop to
    /// completion. A `{% for %}` over a context-provided collection (whose
    /// size the template author does not control) is unaffected by this
    /// check — it is caught, if it produces too much text, by the
    /// whole-render output-size check once rendering completes (plan.md
    /// §4).
    ///
    /// - Throws: `UntrustedTemplateError.outputTooLarge` when a literal
    ///   range's span exceeds `untrustedOutputSizeLimit`.
    private static func validateForLoopRange(_ token: Token) throws {
        guard let iterableComponent = token.components.last(where: { $0.contains("...") }),
            let separatorRange = iterableComponent.range(of: "..."),
            let lowerBound = Int(iterableComponent[iterableComponent.startIndex..<separatorRange.lowerBound]),
            let upperBound = Int(iterableComponent[separatorRange.upperBound...])
        else {
            return
        }
        // `Int128` arithmetic here is not a style choice: `lowerBound` and
        // `upperBound` are attacker-controlled `Int` literals, and plain
        // `Int` subtraction (e.g. `upperBound - lowerBound` near
        // `Int.max`/`Int.min`) traps — crashing the host process, which is
        // strictly worse than the slow-render bug this check exists to
        // close. `Int128` has room for the difference of any two `Int`
        // values (and its negation) with no overflow, so the span is
        // always computed exactly.
        let span = Int128(upperBound) - Int128(lowerBound)
        let absoluteSpan = span < 0 ? -span : span
        guard absoluteSpan + 1 <= Int128(untrustedOutputSizeLimit) else {
            throw UntrustedTemplateError.outputTooLarge(limit: untrustedOutputSizeLimit)
        }
    }

    /// The tag name a `.block` token invokes — `token.components.first`,
    /// except for a labeled loop tag (`{% outer: for ... %}`), where the
    /// real tag name is the second component and the first is the label
    /// (mirrors Stencil's own `TokenParser.parse` special case for labeled
    /// `for` loops).
    private static func tagName(from token: Token) -> String {
        let components = token.components
        guard let first = components.first else { return token.contents }
        if first.hasSuffix(":") && components.count >= 2 {
            return components[1]
        }
        return first
    }

    /// The filter names a `.variable` token applies, in left-to-right
    /// order, e.g. `{{ name|default:"x"|upper }}` → `["default", "upper"]`.
    /// Empty when the token applies no filters.
    private static func filterNames(from token: Token) -> [String] {
        let segments = splitRespectingQuotes(token.contents, separator: "|")
        return segments.dropFirst().map { segment in
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard let colonIndex = trimmed.firstIndex(of: ":") else { return trimmed }
            return String(trimmed[trimmed.startIndex..<colonIndex])
        }
    }

    /// Splits `text` on `separator`, treating single- and double-quoted
    /// substrings as atomic — mirrors Stencil's own filter-argument
    /// splitting convention, so a `|` inside a quoted filter argument is
    /// never mistaken for a filter pipe.
    private static func splitRespectingQuotes(_ text: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var activeQuote: Character?
        for character in text {
            if let quote = activeQuote {
                current.append(character)
                if character == quote { activeQuote = nil }
            } else if character == "\"" || character == "'" {
                activeQuote = character
                current.append(character)
            } else if character == separator {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result
    }
}

/// `Trust.untrusted`'s sole custom `Extension`: replaces Stencil's own
/// `include` tag with `RestrictedIncludeNode`, which enforces
/// `TemplateEngine.untrustedIncludeDepthLimit` and re-validates each loaded
/// partial's own tags/filters against the untrusted whitelist —
/// protections Stencil's own `include` implementation (an internal Stencil
/// type this package cannot subclass or wrap) has no hook for. Registered
/// ahead of Stencil's `DefaultExtension` (which `Environment.init` always
/// appends), so `Environment.findTag(name: "include")` resolves to this
/// implementation first; every other default tag (`if`, `for`, and the
/// rest) falls through unchanged to `DefaultExtension` — restricted only by
/// the separate whitelist check `TemplateEngine.render` runs before
/// rendering ever begins.
final class RestrictedIncludeExtension: Extension {
    override init() {
        super.init()
        registerTag("include", parser: RestrictedIncludeNode.parse)
    }
}

/// `Trust.untrusted`'s replacement for Stencil's own `{% include %}` node:
/// the same argument syntax and `DotfolderLoader` resolution as the trusted
/// path, plus two protections the trusted path skips (plan.md §4):
/// `TemplateEngine.untrustedIncludeDepthLimit` (a self- or mutually
/// including partial cannot recurse without bound) and re-running the
/// untrusted tag/filter whitelist over the loaded partial's own tokens (a
/// malicious partial cannot smuggle in a disallowed construct just because
/// the top-level template that includes it was clean).
final class RestrictedIncludeNode: NodeType {
    /// The `Context` dictionary key this node stashes the current include
    /// nesting depth under (an `Int`, incremented per nested render).
    static let depthContextKey = "__foundationModelsExtras_untrustedIncludeDepth__"

    /// The `Context` dictionary key `TemplateEngine.render` stashes the
    /// shared `OutputSizeBudget` under, once, at the top of the render.
    static let sizeBudgetContextKey = "__foundationModelsExtras_untrustedOutputSizeBudget__"

    /// The template name to load, resolved from the tag's first argument.
    let templateName: Variable
    /// The optional second argument naming a context variable to pass to
    /// the included template, exactly as Stencil's own `include` supports.
    let includeContext: String?
    /// This node's source token. Required by the `NodeType` protocol
    /// (`var token: Token? { get }`) — not unused scaffolding, even though
    /// nothing in this file reads `self.token` directly: Stencil's own
    /// `renderNodes(_:_:)` (`Node.swift`) reads every node's `token` via
    /// `node.token` whenever that node's `render` throws, and uses it to
    /// wrap the error in a `TemplateSyntaxError` carrying this token's
    /// source location. That re-wrap is exactly what `UntrustedTemplateError`'s
    /// doc comment above describes ("re-wraps any non-`TemplateSyntaxError`
    /// in a `TemplateSyntaxError`") — this property is the mechanism behind
    /// it, supplied by protocol conformance rather than by a call site here.
    let token: Token?

    /// Parses `{% include "name" %}` / `{% include "name" contextVar %}` —
    /// identical syntax to Stencil's own `include` tag.
    static func parse(_ parser: TokenParser, token: Token) throws -> NodeType {
        let bits = token.components
        guard bits.count == 2 || bits.count == 3 else {
            throw TemplateSyntaxError(
                """
                'include' tag requires one argument, the template file to be included. \
                A second optional argument can be used to specify the context that will \
                be passed to the included file
                """
            )
        }
        return RestrictedIncludeNode(
            templateName: Variable(bits[1]), includeContext: bits.count == 3 ? bits[2] : nil, token: token)
    }

    /// Creates a node for the given parsed arguments.
    init(templateName: Variable, includeContext: String?, token: Token?) {
        self.templateName = templateName
        self.includeContext = includeContext
        self.token = token
    }

    /// Loads and renders the included template, enforcing the untrusted
    /// include-depth limit and re-validating the loaded template's tokens
    /// against the untrusted whitelist first.
    func render(_ context: Context) throws -> String {
        guard let templateName = try self.templateName.resolve(context) as? String else {
            throw TemplateSyntaxError("'\(self.templateName)' could not be resolved as a string")
        }

        let currentDepth = (context[Self.depthContextKey] as? Int) ?? 0
        guard currentDepth < TemplateEngine.untrustedIncludeDepthLimit else {
            throw UntrustedTemplateError.includeDepthExceeded(limit: TemplateEngine.untrustedIncludeDepthLimit)
        }

        let template = try context.environment.loadTemplate(name: templateName)
        try TemplateEngine.validateUntrustedTokens(template.tokens)

        var pushedDictionary = includeContext.flatMap { context[$0] as? [String: Any] } ?? [:]
        pushedDictionary[Self.depthContextKey] = currentDepth + 1

        let rendered = try context.push(dictionary: pushedDictionary) {
            try template.render(context)
        }

        // Checked *after* this include's own render, not before: the
        // budget tracks bytes already produced, so this call's own
        // contribution is the one that (potentially) tips it over —
        // catching a many-small-includes amplification bomb as soon as
        // the running total crosses the limit, rather than only once the
        // entire top-level render has finished.
        if let outputSizeBudget = context[Self.sizeBudgetContextKey] as? OutputSizeBudget {
            outputSizeBudget.consumedBytes += rendered.utf8.count
            guard outputSizeBudget.consumedBytes <= TemplateEngine.untrustedOutputSizeLimit else {
                throw UntrustedTemplateError.outputTooLarge(limit: TemplateEngine.untrustedOutputSizeLimit)
            }
        }

        return rendered
    }
}

/// A shared, mutable running total of `Trust.untrusted` output bytes
/// produced so far by `{% include %}` tags across an entire render —
/// stashed once in the `Context` by `TemplateEngine.render` and found by
/// every `RestrictedIncludeNode` via reference (not value) semantics, so
/// sibling includes at the same nesting level (e.g. many `{% include %}`
/// calls driven by one `{% for %}`) see each other's contribution instead
/// of each starting a fresh budget — closing the amplification gap a
/// per-include check alone would miss (plan.md §4).
final class OutputSizeBudget {
    /// The number of UTF-8 bytes every include this render has resolved
    /// has produced so far, summed.
    var consumedBytes = 0
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
