import Foundation
import Testing

@testable import FoundationModelsExtras

/// Table-driven behavioral tests for `Wildmatch.wildmatch(pattern:path:)`,
/// covering `gitignore(5)` PATTERN FORMAT semantics: `*`, `?`, bracket
/// character classes (ranges, `[!...]`/`[^...]` negation, named POSIX
/// classes), all three `**` forms, and `\`-escapes.
///
/// The corpus below is a representative subset ported from the shapes of
/// git's own `t3070-wildmatch.sh` vectors — the basic fnmatch-style cases
/// (`?`, `*`, bracket ranges) and the `**` cases from `gitignore(5)` — not
/// an exhaustive line-for-line port of that file.
@Suite struct WildmatchTests {

  /// One (pattern, path, expected) case, with a short human-readable label
  /// so a failing parameterized test names the specific scenario.
  struct Case: Sendable, CustomStringConvertible {
    let pattern: String
    let path: String
    let expected: Bool
    let label: String

    var description: String { label }
  }

  static let cases: [Case] = [
    // MARK: Plain literals

    Case(pattern: "foo", path: "foo", expected: true, label: "exact literal match"),
    Case(pattern: "foo", path: "bar", expected: false, label: "exact literal mismatch"),
    Case(pattern: "foo", path: "foobar", expected: false, label: "literal is not a prefix match"),
    Case(pattern: "", path: "", expected: true, label: "empty pattern matches empty path"),
    Case(pattern: "foo", path: "", expected: false, label: "literal does not match empty path"),

    // MARK: `?`

    Case(pattern: "fo?", path: "foo", expected: true, label: "? matches one character"),
    Case(
      pattern: "fo?", path: "fo", expected: false, label: "? requires a character to be present"),
    Case(pattern: "fo?", path: "fooo", expected: false, label: "? matches exactly one character"),
    Case(pattern: "???", path: "foo", expected: true, label: "??? matches a 3-character name"),
    Case(
      pattern: "??", path: "foo", expected: false, label: "?? does not match a 3-character name"),
    Case(
      pattern: "f?o", path: "f/o", expected: false,
      label: "? never matches a path separator (segment-count mismatch)"),

    // MARK: `*` within a segment

    Case(pattern: "*.txt", path: "file.txt", expected: true, label: "* matches any prefix"),
    Case(pattern: "f*", path: "foo", expected: true, label: "trailing * matches the rest"),
    Case(pattern: "*f", path: "foo", expected: false, label: "*f requires the name to end in f"),
    Case(pattern: "*foo*", path: "foo", expected: true, label: "*foo* matches foo itself"),
    Case(
      pattern: "*ob*a*r*", path: "foobar", expected: true,
      label: "multiple * wildcards in one segment"),
    Case(pattern: "*", path: "foo", expected: true, label: "bare * matches any single segment"),

    // MARK: `*` never crosses `/`

    Case(pattern: "foo/*", path: "foo/bar", expected: true, label: "* matches within foo/"),
    Case(
      pattern: "foo/*", path: "foo/bar/baz", expected: false,
      label: "* does not cross into a deeper directory"),
    Case(
      pattern: "*", path: "foo/bar", expected: false,
      label: "bare * does not match a multi-segment path"),

    // MARK: Backslash escapes

    Case(pattern: "\\*", path: "*", expected: true, label: "\\* matches a literal asterisk"),
    Case(pattern: "\\*", path: "x", expected: false, label: "\\* does not act as a wildcard"),
    Case(
      pattern: "a\\?b", path: "a?b", expected: true, label: "\\? matches a literal question mark"),
    Case(pattern: "a\\?b", path: "axb", expected: false, label: "escaped ? is not a wildcard"),
    Case(
      pattern: "foo\\", path: "foo\\", expected: true,
      label: "a trailing lone backslash is a literal backslash"),

    // MARK: Bracket character classes: literals and ranges

    Case(pattern: "[a-c]at", path: "bat", expected: true, label: "range hit"),
    Case(pattern: "[a-c]at", path: "dat", expected: false, label: "range miss"),
    Case(pattern: "[abc]at", path: "cat", expected: true, label: "literal set hit"),
    Case(pattern: "[abc]at", path: "dat", expected: false, label: "literal set miss"),
    Case(
      pattern: "[]a]", path: "]", expected: true,
      label: "] as first class member is a literal ]"),
    Case(
      pattern: "[]a]", path: "a", expected: true,
      label: "] as first member still allows other members"),
    Case(pattern: "[]a]", path: "b", expected: false, label: "] as first member class miss"),

    // MARK: Bracket negation — both spellings

    Case(pattern: "[!a-c]at", path: "dat", expected: true, label: "[!...] negation hit"),
    Case(
      pattern: "[!a-c]at", path: "bat", expected: false, label: "[!...] negation excludes range"),
    Case(pattern: "[^a-c]at", path: "dat", expected: true, label: "[^...] negation hit"),
    Case(
      pattern: "[^a-c]at", path: "bat", expected: false, label: "[^...] negation excludes range"),
    Case(
      pattern: "[!]a]", path: "]", expected: false,
      label: "negated ]-as-first-member excludes ]"),
    Case(
      pattern: "[!]a]", path: "c", expected: true,
      label: "negated ]-as-first-member allows other characters"),

    // MARK: Malformed brackets match nothing, without crashing

    Case(
      pattern: "foo[bar", path: "foo[bar", expected: false, label: "unterminated [ matches nothing"),
    Case(pattern: "[", path: "[", expected: false, label: "bare unterminated [ matches nothing"),
    Case(pattern: "[!", path: "x", expected: false, label: "unterminated [! matches nothing"),

    // MARK: Named POSIX character classes

    Case(pattern: "[[:digit:]]x", path: "5x", expected: true, label: "[:digit:] hit"),
    Case(pattern: "[[:digit:]]x", path: "ax", expected: false, label: "[:digit:] miss"),
    Case(pattern: "[[:alpha:]]x", path: "ax", expected: true, label: "[:alpha:] hit"),
    Case(pattern: "[[:alpha:]]x", path: "1x", expected: false, label: "[:alpha:] miss"),
    Case(pattern: "[[:alnum:]]x", path: "9x", expected: true, label: "[:alnum:] hit (digit)"),
    Case(
      pattern: "[[:alnum:]]x", path: "!x", expected: false, label: "[:alnum:] miss (punctuation)"),
    Case(pattern: "[[:upper:]]x", path: "Ax", expected: true, label: "[:upper:] hit"),
    Case(pattern: "[[:upper:]]x", path: "ax", expected: false, label: "[:upper:] miss"),
    Case(pattern: "[[:lower:]]x", path: "ax", expected: true, label: "[:lower:] hit"),
    Case(pattern: "[[:lower:]]x", path: "Ax", expected: false, label: "[:lower:] miss"),
    Case(pattern: "a[[:space:]]b", path: "a b", expected: true, label: "[:space:] hit"),
    Case(pattern: "a[[:space:]]b", path: "axb", expected: false, label: "[:space:] miss"),
    Case(pattern: "[[:punct:]]x", path: "!x", expected: true, label: "[:punct:] hit"),
    Case(pattern: "[[:punct:]]x", path: "ax", expected: false, label: "[:punct:] miss"),
    Case(
      pattern: "[[:xdigit:]]x", path: "fx", expected: true, label: "[:xdigit:] hit (hex letter)"),
    Case(pattern: "[[:xdigit:]]x", path: "gx", expected: false, label: "[:xdigit:] miss"),
    Case(pattern: "[[:cntrl:]]x", path: "\u{01}x", expected: true, label: "[:cntrl:] hit"),
    Case(pattern: "[[:cntrl:]]x", path: "ax", expected: false, label: "[:cntrl:] miss"),
    Case(pattern: "[[:print:]]x", path: "ax", expected: true, label: "[:print:] hit"),
    Case(pattern: "[[:print:]]x", path: "\u{01}x", expected: false, label: "[:print:] miss"),
    Case(pattern: "[[:graph:]]x", path: "ax", expected: true, label: "[:graph:] hit"),
    Case(pattern: "[[:graph:]]x", path: " x", expected: false, label: "[:graph:] miss (space)"),
    Case(pattern: "a[[:blank:]]b", path: "a\tb", expected: true, label: "[:blank:] hit (tab)"),
    Case(pattern: "a[[:blank:]]b", path: "axb", expected: false, label: "[:blank:] miss"),

    // MARK: `**/` leading — matches in all directories

    Case(pattern: "**/foo", path: "foo", expected: true, label: "leading **/ matches at depth 0"),
    Case(pattern: "**/foo", path: "a/foo", expected: true, label: "leading **/ matches at depth 1"),
    Case(
      pattern: "**/foo", path: "a/b/foo", expected: true, label: "leading **/ matches at depth 2"),
    Case(
      pattern: "**/foo", path: "a/foobar", expected: false,
      label: "leading **/ still requires the final segment to match exactly"),

    // MARK: `/**` trailing — matches everything inside

    Case(
      pattern: "abc/**", path: "abc/x", expected: true, label: "trailing /** matches direct child"),
    Case(
      pattern: "abc/**", path: "abc/x/y", expected: true,
      label: "trailing /** matches nested descendant"),
    Case(
      pattern: "abc/**", path: "abc", expected: false,
      label: "trailing /** does not match the directory itself"),
    Case(
      pattern: "abc/**", path: "abcd", expected: false,
      label: "trailing /** does not match a sibling with a shared prefix"),

    // MARK: `a/**/b` — zero or more intermediate directories

    Case(
      pattern: "a/**/b", path: "a/b", expected: true, label: "a/**/b matches zero intermediate dirs"
    ),
    Case(
      pattern: "a/**/b", path: "a/x/b", expected: true, label: "a/**/b matches one intermediate dir"
    ),
    Case(
      pattern: "a/**/b", path: "a/x/y/b", expected: true,
      label: "a/**/b matches multiple intermediate dirs"),
    Case(
      pattern: "a/**/b", path: "a/b/c", expected: false,
      label: "a/**/b still anchors the trailing b"),
    Case(
      pattern: "foo/**/bar", path: "foo/bar", expected: true,
      label: "another zero-intermediate ** case"),
    Case(
      pattern: "foo/**/**/bar", path: "foo/x/y/bar", expected: true,
      label: "consecutive ** segments compose"),

    // MARK: `**` alone, and `**` mixed into a segment (behaves like `*`)

    Case(pattern: "**", path: "foo", expected: true, label: "bare ** matches a single segment"),
    Case(
      pattern: "**", path: "a/b/c", expected: true, label: "bare ** matches a multi-segment path"),
    Case(
      pattern: "a**b", path: "aXXXb", expected: true,
      label: "** mixed into a segment behaves like a single *"),
    Case(
      pattern: "a**b", path: "aXXX/b", expected: false,
      label: "** mixed into a segment still does not cross /"),

    // MARK: No exponential blowup

    Case(
      pattern: "a*a*a*a*a*a*a*a*b", path: String(repeating: "a", count: 40), expected: false,
      label: "pathological repeated-star pattern still resolves"),
  ]

  @Test(arguments: cases)
  func wildmatchCase(_ testCase: Case) {
    let result = Wildmatch.wildmatch(pattern: testCase.pattern, path: testCase.path)
    #expect(
      result == testCase.expected,
      "wildmatch(pattern: \(testCase.pattern.debugDescription), path: \(testCase.path.debugDescription)) expected \(testCase.expected) but got \(result) [\(testCase.label)]"
    )
  }

  // MARK: - Performance: bounded, not exponential

  /// A pattern with many `*` wildcards against a long run of the character
  /// they can each greedily claim is the classic pathological input for a
  /// naive recursive matcher (exponential blowup). `Wildmatch` uses the
  /// iterative two-pointer algorithm instead, which is
  /// `O(pattern.count * text.count)` — this should resolve in well under a
  /// second even at this size, not time out or exhaust the stack.
  @Test func pathologicalStarPatternDoesNotBlowUp() {
    let pattern = String(repeating: "a*", count: 40) + "b"
    let text = String(repeating: "a", count: 8000)

    let start = Date()
    let result = Wildmatch.wildmatch(pattern: pattern, path: text)
    let elapsed = Date().timeIntervalSince(start)

    #expect(result == false)
    #expect(elapsed < 3.0, "matching took \(elapsed)s — suspect exponential blowup")
  }
}
