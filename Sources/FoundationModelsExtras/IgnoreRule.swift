/// One parsed line of a gitignore-style ignore file, with the provenance
/// needed to explain a match back to the user.
///
/// Parsing follows git's own semantics (`gitignore(5)`, implemented in git's
/// `dir.c`), in git's order:
///
/// 1. A trailing `\r` is stripped first, so CRLF ignore files behave
///    identically to LF ones.
/// 2. Blank lines and lines whose first character is an unescaped `#` are
///    comments — no rule (`init` returns `nil`).
/// 3. Unescaped trailing spaces are stripped; a backslash-escaped space
///    (`\ `) survives, and — matching git's `trim_trailing_spaces` — only
///    spaces are trimmed, never tabs.
/// 4. A leading unescaped `!` sets `isNegated` and is stripped; a leading
///    `\#` or `\!` consumes the backslash, leaving a literal `#` or `!`.
/// 5. A trailing unescaped `/` sets `isDirectoryOnly` and is stripped.
/// 6. A leading `/` sets `isAnchored` and is stripped; any `/` remaining in
///    the pattern after those strips also sets `isAnchored` (git's "NODIR"
///    check: slash-free patterns match the basename at any depth, patterns
///    containing a slash match relative to the ignore file's directory).
///
/// All other backslashes are kept intact in `pattern`: they are fnmatch
/// escapes, resolved at match time, not parse time.
public struct IgnoreRule: Sendable, Equatable {
  /// The effective match pattern, after stripping the syntax markers above.
  /// Never empty — lines that reduce to an empty pattern parse to `nil`.
  public let pattern: String
  /// True when the line began with an unescaped `!` (a re-include rule).
  public let isNegated: Bool
  /// True when the line ended with an unescaped `/` — the rule matches
  /// directories only.
  public let isDirectoryOnly: Bool
  /// True when the line's pattern contains a `/` anywhere other than the
  /// trailing (directory-marker) position — including a stripped leading
  /// `/`. Anchored patterns match relative to the ignore file's directory;
  /// unanchored ones match the basename at any depth.
  public let isAnchored: Bool
  /// Display name of the originating file (e.g. `.gitignore`,
  /// `.reviewignore`), for explaining matches.
  public let source: String
  /// The 1-based line number of `originalText` within `source`.
  public let line: Int
  /// The raw line exactly as passed to the parser (including any trailing
  /// `\r`), for explanations.
  public let originalText: String

  /// Parses one raw ignore-file line into a rule.
  ///
  /// Returns `nil` for lines that produce no rule: blank lines, `#`
  /// comments, and lines whose pattern strips to empty (a lone `!`, `/`, or
  /// `!/`, and whitespace-only lines). Git parses those last shapes to a
  /// pattern that can never match anything, so declining to produce a rule
  /// preserves behavior while keeping the invariant that every `IgnoreRule`
  /// has a non-empty `pattern`.
  ///
  /// - Parameters:
  ///   - line: The raw line text, without its `\n` terminator (a trailing
  ///     `\r` from CRLF input is tolerated and stripped).
  ///   - source: Display name of the originating file.
  ///   - lineNumber: The 1-based line number of `line` within `source`.
  /// - Returns: An `IgnoreRule` instance if parsing succeeds, or `nil` if the
  ///   line is blank, a comment, or reduces to an empty pattern.
  public init?(line: String, source: String, lineNumber: Int) {
    self.source = source
    self.line = lineNumber
    self.originalText = line

    // 1. CRLF tolerance: strip one trailing carriage return.
    var text = Substring(line)
    if text.last == "\r" {
      text = text.dropLast()
    }

    // 2. Blank lines and comments produce no rule. Only a `#` in the very
    // first column comments the line; `\#` is handled as an escape below.
    guard let first = text.first, first != "#" else {
      return nil
    }

    // 3. Strip unescaped trailing spaces (git's trim_trailing_spaces).
    var characters = Self.trimmingTrailingUnescapedSpaces(Array(text))

    // 4. Negation marker, or a `\#`/`\!` escape consumed into its literal.
    if characters.first == "!" {
      self.isNegated = true
      characters.removeFirst()
    } else {
      self.isNegated = false
      if characters.count >= 2, characters[0] == "\\",
        characters[1] == "#" || characters[1] == "!"
      {
        characters.removeFirst()
      }
    }

    // 5. Directory-only marker: an unescaped trailing slash.
    if characters.last == "/", !Self.isEscaped(at: characters.count - 1, in: characters) {
      self.isDirectoryOnly = true
      characters.removeLast()
    } else {
      self.isDirectoryOnly = false
    }

    // 6. Anchoring: a leading slash (stripped), or any slash remaining in
    // the pattern.
    var isAnchored = false
    if characters.first == "/" {
      isAnchored = true
      characters.removeFirst()
    }
    if characters.contains("/") {
      isAnchored = true
    }
    self.isAnchored = isAnchored

    guard !characters.isEmpty else {
      return nil
    }
    self.pattern = String(characters)
  }

  /// Removes the trailing run of unescaped spaces, replicating git's
  /// `trim_trailing_spaces`: scanning left to right, a backslash consumes
  /// the character after it (so `\ ` is not a trailing space), and only
  /// spaces — never tabs — are trimmed.
  ///
  /// - Parameter characters: The line's characters after CRLF stripping.
  /// - Returns: The characters with the trailing unescaped spaces removed.
  private static func trimmingTrailingUnescapedSpaces(_ characters: [Character]) -> [Character] {
    var trailingSpaceStart: Int?
    var index = 0
    while index < characters.count {
      switch characters[index] {
      case " ":
        if trailingSpaceStart == nil {
          trailingSpaceStart = index
        }
      case "\\":
        // The escaped character (if any) cannot start a trailing-space run.
        index += 1
        trailingSpaceStart = nil
      default:
        trailingSpaceStart = nil
      }
      index += 1
    }
    guard let trailingSpaceStart else {
      return characters
    }
    return Array(characters[..<trailingSpaceStart])
  }

  /// Reports whether the character at `index` is backslash-escaped: preceded
  /// by an odd-length run of backslashes (`\/` is escaped, `\\/` is not).
  ///
  /// - Parameters:
  ///   - index: The position of the character to test.
  ///   - characters: The characters containing it.
  /// - Returns: True when an odd number of backslashes immediately precede
  ///   `index`.
  private static func isEscaped(at index: Int, in characters: [Character]) -> Bool {
    var backslashes = 0
    var cursor = index - 1
    while cursor >= 0, characters[cursor] == "\\" {
      backslashes += 1
      cursor -= 1
    }
    return backslashes % 2 == 1
  }
}
