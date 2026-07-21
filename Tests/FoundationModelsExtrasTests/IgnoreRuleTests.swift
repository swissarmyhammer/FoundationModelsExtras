import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `IgnoreRule.init?(line:source:lineNumber:)`, covering
/// git's gitignore(5) line-parsing semantics: comment and blank handling,
/// `\#`/`\!` marker escapes, unescaped-trailing-space stripping, negation,
/// directory-only trailing `/`, anchoring, and CRLF tolerance.
@Suite struct IgnoreRuleTests {
  /// Parses `line` with a fixed provenance, returning the rule (or nil).
  private func rule(_ line: String) -> IgnoreRule? {
    IgnoreRule(line: line, source: ".gitignore", lineNumber: 1)
  }

  // MARK: - Blank lines and comments

  @Test func emptyLineParsesToNil() {
    #expect(rule("") == nil)
  }

  @Test func whitespaceOnlyLineParsesToNil() {
    #expect(rule("   ") == nil)
  }

  @Test func commentLineParsesToNil() {
    #expect(rule("# a comment") == nil)
  }

  @Test func hashWithNoSpaceIsStillAComment() {
    #expect(rule("#foo") == nil)
  }

  @Test func escapedHashIsALiteralHashPattern() {
    let parsed = rule("\\#foo")

    #expect(parsed?.pattern == "#foo")
    #expect(parsed?.isNegated == false)
  }

  @Test func escapedHashAloneIsALiteralHashPattern() {
    #expect(rule("\\#")?.pattern == "#")
  }

  @Test func leadingWhitespaceDoesNotMakeAComment() {
    // Only a `#` in the very first column starts a comment; leading
    // whitespace is significant and stays in the pattern (git behavior).
    #expect(rule("  #x")?.pattern == "  #x")
  }

  // MARK: - Negation

  @Test func leadingBangSetsIsNegatedAndIsStripped() {
    let parsed = rule("!build")

    #expect(parsed?.isNegated == true)
    #expect(parsed?.pattern == "build")
  }

  @Test func escapedBangIsALiteralBangPattern() {
    let parsed = rule("\\!important.txt")

    #expect(parsed?.isNegated == false)
    #expect(parsed?.pattern == "!important.txt")
  }

  @Test func escapedBangAloneIsALiteralBangPattern() {
    let parsed = rule("\\!")

    #expect(parsed?.isNegated == false)
    #expect(parsed?.pattern == "!")
  }

  @Test func loneBangParsesToNil() {
    // `!` with nothing after it negates an empty pattern, which matches
    // nothing in git — no rule is produced.
    #expect(rule("!") == nil)
  }

  // MARK: - Directory-only trailing slash

  @Test func trailingSlashSetsIsDirectoryOnlyAndIsStripped() {
    let parsed = rule("build/")

    #expect(parsed?.isDirectoryOnly == true)
    #expect(parsed?.pattern == "build")
    #expect(parsed?.isAnchored == false)
  }

  @Test func escapedTrailingSlashIsLiteralAndAnchors() {
    // A backslash-escaped trailing `/` is not the directory marker; it stays
    // in the pattern, and the retained slash makes the rule anchored.
    let parsed = rule("foo\\/")

    #expect(parsed?.isDirectoryOnly == false)
    #expect(parsed?.pattern == "foo\\/")
    #expect(parsed?.isAnchored == true)
  }

  @Test func evenBackslashRunBeforeTrailingSlashIsStillDirectoryOnly() {
    // `\\/` ends with an unescaped slash — the two backslashes escape each
    // other — so the directory marker applies and is stripped.
    let parsed = rule("foo\\\\/")

    #expect(parsed?.isDirectoryOnly == true)
    #expect(parsed?.pattern == "foo\\\\")
    #expect(parsed?.isAnchored == false)
  }

  @Test func loneSlashParsesToNil() {
    // `/` alone strips to an empty pattern, which matches nothing in git.
    #expect(rule("/") == nil)
  }

  @Test func negatedLoneSlashParsesToNil() {
    #expect(rule("!/") == nil)
  }

  // MARK: - Anchoring

  @Test func leadingSlashSetsIsAnchoredAndIsStripped() {
    let parsed = rule("/foo")

    #expect(parsed?.isAnchored == true)
    #expect(parsed?.pattern == "foo")
  }

  @Test func interiorSlashSetsIsAnchored() {
    let parsed = rule("doc/frob.txt")

    #expect(parsed?.isAnchored == true)
    #expect(parsed?.pattern == "doc/frob.txt")
  }

  @Test func slashFreeGlobIsNeitherAnchoredNorDirectoryOnly() {
    let parsed = rule("*.log")

    #expect(parsed?.pattern == "*.log")
    #expect(parsed?.isAnchored == false)
    #expect(parsed?.isDirectoryOnly == false)
    #expect(parsed?.isNegated == false)
  }

  @Test func leadingSlashAndTrailingSlashCombine() {
    let parsed = rule("/foo/")

    #expect(parsed?.isAnchored == true)
    #expect(parsed?.isDirectoryOnly == true)
    #expect(parsed?.pattern == "foo")
  }

  @Test func interiorSlashAndTrailingSlashCombine() {
    let parsed = rule("a/b/")

    #expect(parsed?.isAnchored == true)
    #expect(parsed?.isDirectoryOnly == true)
    #expect(parsed?.pattern == "a/b")
  }

  @Test func negationAnchoringAndDirectoryOnlyCombine() {
    let parsed = rule("!/foo/")

    #expect(parsed?.isNegated == true)
    #expect(parsed?.isAnchored == true)
    #expect(parsed?.isDirectoryOnly == true)
    #expect(parsed?.pattern == "foo")
  }

  // MARK: - Trailing whitespace

  @Test func unescapedTrailingSpacesAreStripped() {
    #expect(rule("foo  ")?.pattern == "foo")
  }

  @Test func escapedTrailingSpaceIsPreserved() {
    // The backslash stays in the stored pattern: it is an fnmatch escape,
    // resolved at match time, and the space it protects survives parsing.
    #expect(rule("foo\\ ")?.pattern == "foo\\ ")
  }

  @Test func unescapedSpacesAfterAnEscapedSpaceAreStripped() {
    #expect(rule("foo\\  ")?.pattern == "foo\\ ")
  }

  @Test func trailingTabIsNotStripped() {
    // git's trim_trailing_spaces trims spaces only; tabs are ordinary
    // pattern characters.
    #expect(rule("foo\t")?.pattern == "foo\t")
  }

  @Test func trailingLoneBackslashPreservesPrecedingSpaces() {
    // git's trim_trailing_spaces early-returns on a backslash at end of
    // input, leaving the line untouched — earlier spaces survive.
    #expect(rule("foo \\")?.pattern == "foo \\")
  }

  @Test func negatedLineWithOnlySpacesAfterBangParsesToNil() {
    #expect(rule("!   ") == nil)
  }

  // MARK: - CRLF

  @Test func trailingCarriageReturnIsStripped() {
    #expect(rule("foo\r")?.pattern == "foo")
  }

  @Test func carriageReturnOnlyLineParsesToNil() {
    #expect(rule("\r") == nil)
  }

  @Test func crlfCommentParsesToNil() {
    #expect(rule("# comment\r") == nil)
  }

  @Test func crlfNegationBehavesLikeLfNegation() {
    let parsed = rule("!foo\r")

    #expect(parsed?.isNegated == true)
    #expect(parsed?.pattern == "foo")
  }

  @Test func crlfDirectoryOnlyBehavesLikeLfDirectoryOnly() {
    let parsed = rule("build/\r")

    #expect(parsed?.isDirectoryOnly == true)
    #expect(parsed?.pattern == "build")
  }

  // MARK: - Backslashes in the pattern body

  @Test func interiorBackslashesAreKeptIntact() {
    // Backslashes other than the leading `\#`/`\!` marker escapes are
    // fnmatch escapes, handled at match time — parsing must not consume them.
    #expect(rule("foo\\*bar")?.pattern == "foo\\*bar")
  }

  // MARK: - Provenance

  @Test func provenanceFieldsAreRecordedVerbatim() {
    let parsed = IgnoreRule(line: "!build/\r", source: ".reviewignore", lineNumber: 42)

    #expect(parsed?.source == ".reviewignore")
    #expect(parsed?.line == 42)
    #expect(parsed?.originalText == "!build/\r")
  }

  // MARK: - Equatable

  @Test func identicalParsesAreEqual() {
    let first = IgnoreRule(line: "/foo/", source: ".gitignore", lineNumber: 3)
    let second = IgnoreRule(line: "/foo/", source: ".gitignore", lineNumber: 3)

    #expect(first == second)
  }

  @Test func differingProvenanceMakesRulesUnequal() {
    let first = IgnoreRule(line: "*.log", source: ".gitignore", lineNumber: 1)
    let second = IgnoreRule(line: "*.log", source: ".gitignore", lineNumber: 2)

    #expect(first != second)
  }
}
