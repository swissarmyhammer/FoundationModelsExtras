/// A pure, dependency-free implementation of git's `wildmatch` glob engine,
/// as used to interpret `gitignore(5)` PATTERN FORMAT patterns against a
/// `/`-separated relative path.
///
/// Deliberately does not use `fnmatch(3)` or `NSPredicate`: git's `**`
/// handling and its slash rules diverge from both (POSIX fnmatch has no `**`
/// concept at all, and `NSPredicate`'s `LIKE`/`MATCHES` glob dialect doesn't
/// match `gitignore(5)` semantics either).
///
/// This type is deliberately `internal`: anchoring, basename-vs-path
/// decisions, and negation (`!`) all live one layer up, in the caller that
/// walks `IgnoreRule`s (the `IgnoreProcessor` task). `Wildmatch` itself only
/// answers one pure question — does this single pattern match this single
/// path string — which keeps it trivially testable and reusable.
enum Wildmatch {

  // MARK: - Public entry point

  /// Reports whether `pattern` (in `gitignore(5)` PATTERN FORMAT) matches
  /// `path`, a `/`-separated relative path.
  ///
  /// Every input has a defined result: malformed patterns (e.g. an
  /// unterminated `[`) simply match nothing rather than throwing or
  /// crashing, matching git's own forgiving behavior.
  ///
  /// - Parameters:
  ///   - pattern: The pattern, already stripped of `gitignore(5)` line-level
  ///     syntax (leading `!`, leading/trailing `/`) by `IgnoreRule` — this
  ///     function only interprets the glob body: `*`, `?`, `[...]`, `**`,
  ///     and `\`-escapes.
  ///   - path: The path to test, using `/` as the sole separator.
  /// - Returns: `true` if `pattern` matches `path` under wildmatch rules.
  static func wildmatch(pattern: String, path: String) -> Bool {
    guard let patternSegments = parseSegments(pattern) else {
      // Malformed pattern (e.g. an unterminated `[`): matches nothing.
      return false
    }
    let pathSegments = path.split(separator: "/", omittingEmptySubsequences: false)
      .map(String.init)
    return matches(patternSegments, pathSegments)
  }

  // MARK: - Segment model

  /// One `/`-delimited component of a parsed pattern.
  private enum Segment {
    /// An ordinary component, already tokenized into `PatternToken`s. Never
    /// produced for a component whose raw text is exactly `**` — that's
    /// `.doubleStar` instead. A component that merely *contains* `**`
    /// alongside other characters (`a**b`, `**b`) stays `.literal`: per
    /// `gitignore(5)`, `**` is only magic when it is the *entire* path
    /// component; otherwise the two `*` tokens fold into ordinary
    /// single-`*` behavior in `matchWithinSegment`.
    case literal([PatternToken])
    /// A path component whose raw, unescaped text is exactly `**`.
    case doubleStar
  }

  /// One unit of a tokenized (non-`**`) segment: either a literal character
  /// to match exactly, one of the two single-character wildcards, or a
  /// bracket character class.
  private enum PatternToken {
    case literal(Character)
    case anyChar  // `?`
    case star  // `*`
    case charClass(CharacterClass)
  }

  // MARK: - Splitting the pattern into segments

  /// Splits `pattern` on unescaped `/` characters and classifies each
  /// resulting component as `.doubleStar` or a tokenized `.literal`.
  ///
  /// - Returns: `nil` if any component fails to tokenize (a malformed
  ///   bracket expression) — the caller treats that as "matches nothing".
  private static func parseSegments(_ pattern: String) -> [Segment]? {
    let raw = splitRawSegments(Array(pattern))
    var segments: [Segment] = []
    segments.reserveCapacity(raw.count)
    for component in raw {
      if component.count == 2, component[0] == "*", component[1] == "*" {
        segments.append(.doubleStar)
      } else {
        guard let tokens = tokenize(component) else {
          return nil
        }
        segments.append(.literal(tokens))
      }
    }
    return segments
  }

  /// Splits `characters` on unescaped `/`, keeping a `\/` escape pair intact
  /// (both characters survive into the component; the escape itself is
  /// resolved later by `tokenize`). Mirrors the escape-run scanning used
  /// elsewhere in the family's ignore-file handling (see `IgnoreRule`).
  private static func splitRawSegments(_ characters: [Character]) -> [[Character]] {
    var segments: [[Character]] = [[]]
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "\\", index + 1 < characters.count {
        segments[segments.count - 1].append(character)
        segments[segments.count - 1].append(characters[index + 1])
        index += 2
      } else if character == "/" {
        segments.append([])
        index += 1
      } else {
        segments[segments.count - 1].append(character)
        index += 1
      }
    }
    return segments
  }

  // MARK: - Tokenizing one segment

  /// Converts one `/`-free pattern component into `PatternToken`s,
  /// resolving `\`-escapes and parsing bracket expressions as it goes.
  ///
  /// - Returns: `nil` if a `[` bracket expression is never closed.
  private static func tokenize(_ segment: [Character]) -> [PatternToken]? {
    var tokens: [PatternToken] = []
    var index = 0
    while index < segment.count {
      let character = segment[index]
      switch character {
      case "\\":
        // A backslash escapes the next character, if any. A trailing lone
        // backslash (nothing left to escape) is kept as a literal
        // backslash — no crash, no special meaning.
        if index + 1 < segment.count {
          tokens.append(.literal(segment[index + 1]))
          index += 2
        } else {
          tokens.append(.literal("\\"))
          index += 1
        }
      case "*":
        tokens.append(.star)
        index += 1
      case "?":
        tokens.append(.anyChar)
        index += 1
      case "[":
        guard let (charClass, next) = parseCharacterClass(segment, openBracket: index) else {
          return nil
        }
        tokens.append(.charClass(charClass))
        index = next
      default:
        tokens.append(.literal(character))
        index += 1
      }
    }
    return tokens
  }

  // MARK: - Matching segments against path components

  /// Matches a full pattern-segment list against a full path-segment list.
  ///
  /// Uses a bottom-up DP table `dp[i][j]` = "does `patternSegments[0..<i]`
  /// match `pathSegments[0..<j]`?" over *segment counts*, not characters, so
  /// it is `O(patternSegments.count * pathSegments.count)` — polynomial, not
  /// exponential — even for patterns containing several `**` components.
  ///
  /// `.doubleStar` segments use one of two recurrences depending on
  /// position, per `gitignore(5)`:
  /// - Leading, sole, or interior `**` (`**/foo`, `a/**/b`, or a pattern
  ///   that is just `**`) may consume **zero or more** path segments, so
  ///   `**/foo` matches bare `foo` and `a/**/b` matches bare `a/b`.
  /// - A genuinely *trailing* `**` (`abc/**`, where `**` is the last
  ///   segment of a multi-segment pattern) means "everything inside" per
  ///   the spec text, so it must consume **one or more** path segments:
  ///   `abc/**` matches `abc/x` but not bare `abc`.
  private static func matches(_ patternSegments: [Segment], _ pathSegments: [String]) -> Bool {
    let patternCount = patternSegments.count
    let pathCount = pathSegments.count

    var dp = [[Bool]](
      repeating: [Bool](repeating: false, count: pathCount + 1),
      count: patternCount + 1)
    dp[0][0] = true

    guard patternCount > 0 else {
      // Empty pattern matches only the empty path.
      return dp[0][pathCount]
    }

    for i in 1...patternCount {
      switch patternSegments[i - 1] {
      case .doubleStar:
        let isTrailing = (i == patternCount) && (patternCount > 1)
        fillDoubleStarRow(&dp, at: i, pathCount: pathCount, requiresAtLeastOne: isTrailing)
      case .literal(let tokens):
        fillLiteralRow(&dp, at: i, pathCount: pathCount, tokens: tokens, pathSegments: pathSegments)
      }
    }

    return dp[patternCount][pathCount]
  }

  /// Fills DP row `i` for a `.doubleStar` pattern segment.
  ///
  /// - Parameter requiresAtLeastOne: `true` for a genuinely trailing `**`
  ///   ("one or more" path segments — see `matches(_:_:)`'s doc comment);
  ///   `false` for every other position ("zero or more").
  private static func fillDoubleStarRow(
    _ dp: inout [[Bool]], at i: Int, pathCount: Int, requiresAtLeastOne: Bool
  ) {
    dp[i][0] = requiresAtLeastOne ? false : dp[i - 1][0]
    guard pathCount > 0 else { return }
    for j in 1...pathCount {
      let consumesFromHere = requiresAtLeastOne ? dp[i - 1][j - 1] : dp[i - 1][j]
      dp[i][j] = consumesFromHere || dp[i][j - 1]
    }
  }

  /// Fills DP row `i` for a `.literal` pattern segment, which always
  /// consumes exactly one path segment (so `dp[i][0]` is always `false`).
  private static func fillLiteralRow(
    _ dp: inout [[Bool]], at i: Int, pathCount: Int, tokens: [PatternToken],
    pathSegments: [String]
  ) {
    dp[i][0] = false
    guard pathCount > 0 else { return }
    for j in 1...pathCount {
      dp[i][j] = dp[i - 1][j - 1] && matchWithinSegment(tokens, Array(pathSegments[j - 1]))
    }
  }

  /// Matches a tokenized pattern segment (no `/`) against one path
  /// component (also guaranteed `/`-free) using the classic iterative
  /// two-pointer wildcard algorithm: a forward scan that remembers the most
  /// recent `*` as a backtrack point, rewinding to it (and advancing its
  /// claimed match by one character) on a mismatch instead of recursing.
  ///
  /// This is the piece that satisfies the "no exponential blowup"
  /// requirement: unlike a naive recursive matcher, which can revisit the
  /// same `(patternIndex, textIndex)` pair exponentially many times when a
  /// pattern has several `*`s (e.g. `a*a*a*a*b` against a long run of
  /// `a`s), this scan is `O(pattern.count * text.count)` in the worst case
  /// — bounded and polynomial — because `matchIndex` only ever advances.
  private static func matchWithinSegment(_ pattern: [PatternToken], _ text: [Character]) -> Bool {
    var patternIndex = 0
    var textIndex = 0
    var starIndex: Int? = nil
    var starMatchIndex = 0

    while textIndex < text.count {
      if patternIndex < pattern.count,
        matchesSingleCharacter(pattern[patternIndex], text[textIndex])
      {
        patternIndex += 1
        textIndex += 1
      } else if patternIndex < pattern.count, isStar(pattern[patternIndex]) {
        starIndex = patternIndex
        starMatchIndex = textIndex
        patternIndex += 1
      } else if let star = starIndex {
        // Backtrack: let the most recent `*` claim one more character.
        patternIndex = star + 1
        starMatchIndex += 1
        textIndex = starMatchIndex
      } else {
        return false
      }
    }

    // Trailing stars in the pattern match the empty remainder.
    while patternIndex < pattern.count, isStar(pattern[patternIndex]) {
      patternIndex += 1
    }
    return patternIndex == pattern.count
  }

  private static func isStar(_ token: PatternToken) -> Bool {
    if case .star = token { return true }
    return false
  }

  /// Matches one non-`*` token against one input character. `?` and
  /// character classes never see `/` here — segments are already
  /// slash-free by construction — so no separate "except `/`" check is
  /// needed at this layer.
  private static func matchesSingleCharacter(_ token: PatternToken, _ character: Character) -> Bool
  {
    switch token {
    case .literal(let literal):
      return literal == character
    case .anyChar:
      return true
    case .star:
      return false
    case .charClass(let charClass):
      return charClass.matches(character)
    }
  }

  // MARK: - Bracket character classes

  /// A parsed `[...]` bracket expression: an optionally-negated set of
  /// members (literal characters, `a-z` ranges, and named POSIX classes).
  private struct CharacterClass {
    let negate: Bool
    let members: [ClassMember]

    func matches(_ character: Character) -> Bool {
      let hit = members.contains { $0.matches(character) }
      return negate ? !hit : hit
    }
  }

  private enum ClassMember {
    case literal(Character)
    case range(Character, Character)
    case posix(PosixClass)

    func matches(_ character: Character) -> Bool {
      switch self {
      case .literal(let literal):
        return literal == character
      case .range(let low, let high):
        guard let c = character.unicodeScalars.first, character.unicodeScalars.count == 1,
          let l = low.unicodeScalars.first, low.unicodeScalars.count == 1,
          let h = high.unicodeScalars.first, high.unicodeScalars.count == 1
        else {
          return false
        }
        return l.value <= c.value && c.value <= h.value
      case .posix(let posixClass):
        return posixClass.matches(character)
      }
    }
  }

  /// The twelve named POSIX character classes gitignore's wildmatch
  /// recognizes inside brackets (`[[:alpha:]]` and friends), mapped to
  /// plain ASCII predicates per the task spec — these classes are defined
  /// over the ASCII repertoire, so any non-ASCII character simply fails
  /// every class.
  private enum PosixClass: String {
    case alnum, alpha, blank, cntrl, digit, graph, lower, print, punct, space, upper, xdigit

    // Named as `spaceByte`/`tabByte`/`deleteByte` (not `space`/`tab`/`delete`)
    // because `space` already names a case of this very enum — Swift
    // enum-case and static-property names share one namespace.

    /// ASCII space, the low end of the printable/graphic ranges and a
    /// `.blank`/`.space` member in its own right.
    private static let spaceByte: UInt8 = 0x20
    /// ASCII horizontal tab (`\t`), used by `.blank` and `.space`.
    private static let tabByte: UInt8 = 0x09
    /// ASCII DEL, the upper bound of the printable/graphic ranges and a
    /// `.cntrl` member in its own right.
    private static let deleteByte: UInt8 = 0x7F

    func matches(_ character: Character) -> Bool {
      guard let ascii = character.asciiValue else {
        return false
      }
      switch self {
      case .alnum: return Self.isAlpha(ascii) || Self.isDigit(ascii)
      case .alpha: return Self.isAlpha(ascii)
      case .blank: return ascii == Self.spaceByte || ascii == Self.tabByte
      case .cntrl: return ascii < Self.spaceByte || ascii == Self.deleteByte
      case .digit: return Self.isDigit(ascii)
      case .graph: return ascii > Self.spaceByte && ascii < Self.deleteByte
      case .lower: return ascii >= 0x61 && ascii <= 0x7A
      case .print: return ascii >= Self.spaceByte && ascii < Self.deleteByte
      case .punct: return Self.isPunct(ascii)
      case .space:
        return ascii == Self.spaceByte || (ascii >= Self.tabByte && ascii <= 0x0D)
      case .upper: return ascii >= 0x41 && ascii <= 0x5A
      case .xdigit:
        return Self.isDigit(ascii) || (ascii >= 0x41 && ascii <= 0x46)
          || (ascii >= 0x61 && ascii <= 0x66)
      }
    }

    private static func isAlpha(_ ascii: UInt8) -> Bool {
      (ascii >= 0x41 && ascii <= 0x5A) || (ascii >= 0x61 && ascii <= 0x7A)
    }
    private static func isDigit(_ ascii: UInt8) -> Bool {
      ascii >= 0x30 && ascii <= 0x39
    }
    private static func isPunct(_ ascii: UInt8) -> Bool {
      (ascii > spaceByte && ascii < deleteByte) && !isAlpha(ascii) && !isDigit(ascii)
    }
  }

  /// Parses one bracket expression starting at `segment[openBracket]`
  /// (which must be `[`), following POSIX bracket-expression rules:
  /// - An immediately-following `!` or `^` negates the class (git accepts
  ///   both spellings).
  /// - A `]` in the very first member position (right after `[`, or after
  ///   the negation marker) is a literal `]`, not the closing bracket —
  ///   the standard "close bracket must be escaped by position" rule.
  /// - `[:name:]` is a named POSIX class member.
  /// - `x-y` is a range; a `-` that can't form a range (at the edges, or
  ///   immediately before the closing `]`) is a literal `-`.
  ///
  /// - Returns: The parsed class and the index just past the closing `]`,
  ///   or `nil` if the `[` is never closed.
  private static func parseCharacterClass(
    _ segment: [Character], openBracket: Int
  ) -> (CharacterClass, Int)? {
    var index = openBracket + 1
    guard index < segment.count else { return nil }

    var negate = false
    if segment[index] == "!" || segment[index] == "^" {
      negate = true
      index += 1
      guard index < segment.count else { return nil }
    }

    var members: [ClassMember] = []
    var isFirstMember = true

    while true {
      guard index < segment.count else {
        // Unterminated bracket expression.
        return nil
      }
      if segment[index] == "]", !isFirstMember {
        return (CharacterClass(negate: negate, members: members), index + 1)
      }
      isFirstMember = false

      // Named POSIX class: `[:name:]`.
      if segment[index] == "[", index + 1 < segment.count, segment[index + 1] == ":" {
        guard let closeColon = findPosixClassClose(segment, from: index + 2) else {
          return nil
        }
        let name = String(segment[(index + 2)..<closeColon])
        guard let posixClass = PosixClass(rawValue: name) else {
          // Unknown named class: treat the whole expression as malformed
          // rather than guessing at its meaning.
          return nil
        }
        members.append(.posix(posixClass))
        index = closeColon + 2  // past the ":]"
        continue
      }

      // A `lo-hi` range, or a plain literal.
      let candidate = segment[index]
      if index + 2 < segment.count, segment[index + 1] == "-", segment[index + 2] != "]" {
        members.append(.range(candidate, segment[index + 2]))
        index += 3
      } else {
        members.append(.literal(candidate))
        index += 1
      }
    }
  }

  /// Finds the index of the `:` that opens the closing `:]` of a
  /// `[:name:]` POSIX class, scanning from just after the opening `[:`.
  ///
  /// - Returns: The index of that `:`, or `nil` if `:]` never appears.
  private static func findPosixClassClose(_ segment: [Character], from start: Int) -> Int? {
    var index = start
    while index + 1 < segment.count {
      if segment[index] == ":", segment[index + 1] == "]" {
        return index
      }
      index += 1
    }
    return nil
  }
}
