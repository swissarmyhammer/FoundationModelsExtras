import Foundation

/// Errors thrown by `IgnoreProcessor.init(contentsOf:)` — the package's own
/// error type, mirroring the facade-error style of `DotfolderLoaderError`:
/// no `Foundation`-internal error (e.g. `CocoaError`) ever crosses this
/// boundary, only this documented, `CustomStringConvertible` type.
public enum IgnoreProcessorError: Error, Sendable, CustomStringConvertible {
  /// The file at `path` does not exist, is not readable, or is not valid
  /// UTF-8 text.
  case fileNotReadable(path: String)

  /// A human-readable description naming the unreadable path.
  public var description: String {
    switch self {
    case .fileNotReadable(let path):
      return "ignore file not found or unreadable: \(path)"
    }
  }
}

/// The outcome of evaluating one path against an `IgnoreProcessor`'s rules:
/// whether the path is ignored, and why.
public struct IgnoreVerdict: Sendable, Equatable, CustomStringConvertible {
  /// `true` when the path is ignored (excluded); `false` when it is
  /// included (kept).
  public let isIgnored: Bool
  /// Explains what produced `isIgnored`.
  public let reason: Reason

  /// Why a path evaluated the way it did.
  public enum Reason: Sendable, Equatable {
    /// The last rule in the processor's list whose pattern matched the
    /// path decided the verdict — `isIgnored` follows `rule.isNegated`
    /// (negated rules include; all others ignore).
    case matched(IgnoreRule)
    /// No rule matched the path itself, but an ancestor directory of the
    /// path evaluated to ignored, and no later rule re-included that
    /// ancestor: the path is ignored, and cannot be re-included by a rule
    /// naming the path (or any of its ancestors below `ancestor`) directly.
    ///
    /// `ancestor` is the excluded directory's path (relative to the ignore
    /// file's root); `by` is the rule that excluded it.
    case parentExcluded(ancestor: String, by: IgnoreRule)
    /// No rule matched the path, and no ancestor of it is excluded either:
    /// the path is included by default.
    case noRuleMatched
  }

  /// A human-readable explanation of this verdict, e.g.
  /// `ignored by ".gitignore":3 \`*.log\`` or
  /// `included (no rule matched)`.
  public var description: String {
    switch reason {
    case .matched(let rule):
      let verb = isIgnored ? "ignored" : "included"
      return "\(verb) by \"\(rule.source)\":\(rule.line) `\(Self.ruleText(rule))`"
    case .parentExcluded(let ancestor, let rule):
      return
        "ignored by \"\(rule.source)\":\(rule.line) `\(Self.ruleText(rule))` (parent \"\(ancestor)\" excluded)"
    case .noRuleMatched:
      return "included (no rule matched)"
    }
  }

  /// Reconstructs `rule`'s effective line text for use in explanations.
  ///
  /// Its negation marker and directory-only marker are restored around its
  /// bare `pattern`. Not necessarily byte-identical to `rule.originalText`
  /// (which may carry trailing whitespace or a CRLF `\r`); this is the
  /// pattern's normalized, display-friendly form.
  private static func ruleText(_ rule: IgnoreRule) -> String {
    var text = rule.pattern
    if rule.isDirectoryOnly {
      text += "/"
    }
    if rule.isNegated {
      text = "!" + text
    }
    return text
  }
}

/// An ordered list of `IgnoreRule`s, with the provenance to explain a
/// match, loaded from any file name (not just `.gitignore`) — `.gitignore`,
/// `.reviewignore`, or any other gitignore-syntax file — plus an evaluator
/// implementing git's `gitignore(5)` matching semantics: last-match-wins,
/// negation, anchoring, directory-only rules, and parent-directory
/// exclusion.
///
/// Immutable after construction and `Sendable`, matching the family's
/// prevailing style.
///
/// ## Combining processors with `+`
///
/// Two processors combine with `+` into one whose rule list is the left
/// operand's rules followed by the right operand's, provenance intact.
/// Under last-match-wins evaluation this means the right operand's rules
/// override the left's wherever both match — the same layering git itself
/// applies to its own ignore sources, where a later, higher-precedence file
/// wins:
///
///     let ignores =
///       try IgnoreProcessor(contentsOf: gitignoreURL)
///       + IgnoreProcessor(contentsOf: reviewignoreURL)
///
/// `+=` accumulates a right-hand processor's rules onto a `var` in place:
///
///     var ignores = try IgnoreProcessor(contentsOf: gitignoreURL)
///     ignores += try IgnoreProcessor(contentsOf: reviewignoreURL)
///
/// Combination is associative — `(a + b) + c` evaluates identically to
/// `a + (b + c)` — so any number of ignore sources can be layered in a
/// fixed precedence order regardless of how the combination is grouped.
public struct IgnoreProcessor: Sendable {
  /// Every rule this processor evaluates against, in file order (the order
  /// `evaluate` applies last-match-wins over).
  public let rules: [IgnoreRule]

  /// Loads and parses an ignore file from disk.
  ///
  /// - Parameter url: The file to load. Its last path component (e.g.
  ///   `.gitignore`, `.reviewignore`) becomes every parsed rule's `source`.
  /// - Throws: `IgnoreProcessorError.fileNotReadable` if `url` does not
  ///   exist, cannot be read, or is not valid UTF-8 text.
  public init(contentsOf url: URL) throws {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      throw IgnoreProcessorError.fileNotReadable(path: url.path)
    }
    self.init(string: text, source: url.lastPathComponent)
  }

  /// Parses an ignore file's contents already held in memory — for tests
  /// and for embedded default rule sets that don't live on disk.
  ///
  /// - Parameters:
  ///   - string: The ignore file's raw text, one rule per line, `\n`- or
  ///     `\r\n`-separated.
  ///   - source: Display name recorded on every parsed rule (e.g.
  ///     `.gitignore`), used in verdict explanations.
  public init(string: String, source: String) {
    var rules: [IgnoreRule] = []
    // Splits on Unicode scalars, not `Character`s: Swift's `Character` treats
    // a CRLF pair as a single extended grapheme cluster, so a
    // `Character`-based `split(separator: "\n")` fails to split at a CRLF
    // line boundary at all (it only matches a lone `"\n"`), silently
    // merging that line with the next and corrupting every subsequent
    // line's 1-based number. `Unicode.Scalar` has no such clustering, so
    // `\r` and `\n` are always distinct scalars here — each line still
    // carries its own trailing `\r`, stripped by `IgnoreRule` itself.
    let lineScalars = string.unicodeScalars.split(
      separator: "\n", omittingEmptySubsequences: false)
    for (index, scalars) in lineScalars.enumerated() {
      let line = String(String.UnicodeScalarView(scalars))
      if let rule = IgnoreRule(line: line, source: source, lineNumber: index + 1) {
        rules.append(rule)
      }
    }
    self.rules = rules
  }

  /// Assembles a processor directly from an already-parsed rule list —
  /// used internally by `+`/`+=` to combine two processors without
  /// re-parsing any text.
  private init(rules: [IgnoreRule]) {
    self.rules = rules
  }

  /// Combines two processors into one whose rule list is `lhs`'s rules
  /// followed by `rhs`'s rules, with every rule's original source and line
  /// preserved for verdict explanations.
  ///
  /// Under last-match-wins evaluation, appending `rhs`'s rules after
  /// `lhs`'s means `rhs` overrides `lhs` wherever both match a path — the
  /// same layering git itself uses across its own ignore sources, where a
  /// later, higher-precedence file (e.g. `.gitignore`) overrides an
  /// earlier, lower-precedence one (e.g. `.git/info/exclude`):
  ///
  ///     let ignores =
  ///       try IgnoreProcessor(contentsOf: gitignoreURL)
  ///       + IgnoreProcessor(contentsOf: reviewignoreURL)
  ///
  /// Combination is associative: `(a + b) + c` evaluates identically to
  /// `a + (b + c)`.
  ///
  /// - Parameters:
  ///   - lhs: The lower-precedence processor.
  ///   - rhs: The higher-precedence processor, whose rules are appended
  ///     after `lhs`'s and so win any conflict.
  /// - Returns: A new processor evaluating `lhs`'s rules followed by
  ///   `rhs`'s.
  public static func + (lhs: IgnoreProcessor, rhs: IgnoreProcessor) -> IgnoreProcessor {
    IgnoreProcessor(rules: lhs.rules + rhs.rules)
  }

  /// Accumulates `rhs`'s rules onto `lhs` in place — ergonomic sugar for
  /// `lhs = lhs + rhs`, for building up a combined processor from several
  /// sources one at a time:
  ///
  ///     var ignores = try IgnoreProcessor(contentsOf: gitignoreURL)
  ///     ignores += try IgnoreProcessor(contentsOf: reviewignoreURL)
  ///
  /// - Parameters:
  ///   - lhs: The processor to accumulate onto; reassigned to the combined
  ///     result.
  ///   - rhs: The higher-precedence processor whose rules are appended.
  public static func += (lhs: inout IgnoreProcessor, rhs: IgnoreProcessor) {
    lhs = lhs + rhs
  }

  /// Evaluates a single path against this processor's rules.
  ///
  /// - Parameters:
  ///   - path: A `/`-separated path relative to the ignore file's root. A
  ///     leading `./` is stripped before matching. Absolute paths and `..`
  ///     components are the caller's responsibility to relativize first —
  ///     this method does not resolve them.
  ///   - isDirectory: Whether `path` names a directory. Ignored (and
  ///     implied `true`) when `path` itself ends in `/` — matching git's
  ///     `check-ignore` convention, `evaluate("build/")` is equivalent to
  ///     `evaluate("build", isDirectory: true)`.
  /// - Returns: The verdict: whether `path` is ignored, and why.
  public func evaluate(_ path: String, isDirectory: Bool = false) -> IgnoreVerdict {
    var normalizedPath = Substring(path)
    var effectiveIsDirectory = isDirectory
    if normalizedPath.hasSuffix("/") {
      effectiveIsDirectory = true
      while normalizedPath.hasSuffix("/") {
        normalizedPath = normalizedPath.dropLast()
      }
    }
    while normalizedPath.hasPrefix("./") {
      normalizedPath = normalizedPath.dropFirst(2)
    }

    guard !normalizedPath.isEmpty else {
      return IgnoreVerdict(isIgnored: false, reason: .noRuleMatched)
    }

    let components = normalizedPath.split(separator: "/", omittingEmptySubsequences: false)
      .map(String.init)

    if let excludedAncestor = excludedAncestor(forStrictAncestorsOf: components) {
      return IgnoreVerdict(
        isIgnored: true,
        reason: .parentExcluded(ancestor: excludedAncestor.path, by: excludedAncestor.rule))
    }

    let fullPath = components.joined(separator: "/")
    if let rule = lastMatchingRule(path: fullPath, isDirectory: effectiveIsDirectory) {
      return IgnoreVerdict(isIgnored: !rule.isNegated, reason: .matched(rule))
    }

    return IgnoreVerdict(isIgnored: false, reason: .noRuleMatched)
  }

  /// Evaluates several paths in one call, preserving input order — a
  /// convenience over calling `evaluate(_:isDirectory:)` once per path.
  ///
  /// Each path applies the same trailing-slash directory-probe convention
  /// individually.
  ///
  /// - Parameter paths: The paths to evaluate.
  /// - Returns: One verdict per input path, in the same order.
  public func evaluate(_ paths: [String]) -> [IgnoreVerdict] {
    paths.map { evaluate($0) }
  }

  /// Walks `components`' strict ancestor directories (every prefix shorter
  /// than the full path), shallowest first, looking for the first one whose
  /// own last-match-wins verdict is ignored. Once found, that ancestor's
  /// exclusion is locked in for every deeper level — matching git's "not
  /// possible to re-include a file if a parent directory is excluded", and
  /// its mirror image: a later rule that re-includes that same ancestor
  /// path (folded into the ancestor's own last-match-wins verdict) lifts
  /// the exclusion entirely, since it's never recorded in the first place.
  ///
  /// - Parameter components: The full path's `/`-separated components.
  /// - Returns: The shallowest excluding ancestor's relative path and the
  ///   rule that excluded it, or `nil` if no strict ancestor is excluded.
  private func excludedAncestor(
    forStrictAncestorsOf components: [String]
  ) -> (path: String, rule: IgnoreRule)? {
    guard components.count > 1 else { return nil }

    var prefix: [String] = []
    for component in components.dropLast() {
      prefix.append(component)
      let prefixPath = prefix.joined(separator: "/")
      if let rule = lastMatchingRule(path: prefixPath, isDirectory: true), !rule.isNegated {
        return (prefixPath, rule)
      }
    }
    return nil
  }

  /// The last rule in `rules` (in file order — last-match-wins) whose
  /// pattern matches `path` under this rule's anchoring and directory-only
  /// constraints.
  ///
  /// Anchored rules match `path` in full via `Wildmatch`. Unanchored rules
  /// — guaranteed slash-free by `IgnoreRule`'s own parsing — are matched
  /// against only `path`'s final component, equivalent to implicitly
  /// prefixing the pattern with `**/`.
  ///
  /// - Parameters:
  ///   - path: The full, `/`-separated relative path (or ancestor prefix)
  ///     being probed.
  ///   - isDirectory: Whether the probe names a directory; directory-only
  ///     rules are skipped entirely when this is `false`.
  /// - Returns: The winning rule, or `nil` if no rule matches.
  private func lastMatchingRule(path: String, isDirectory: Bool) -> IgnoreRule? {
    var winner: IgnoreRule?
    let basename = path.split(separator: "/").last.map(String.init) ?? path
    for rule in rules {
      if rule.isDirectoryOnly, !isDirectory {
        continue
      }
      let matched =
        rule.isAnchored
        ? Wildmatch.wildmatch(pattern: rule.pattern, path: path)
        : Wildmatch.wildmatch(pattern: rule.pattern, path: basename)
      if matched {
        winner = rule
      }
    }
    return winner
  }
}
