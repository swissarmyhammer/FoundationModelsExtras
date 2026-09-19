import Foundation
import Testing

@testable import Marketplace

/// Tests for ``SourcePattern`` (marketplace.md §6.7).
///
/// A pattern matches the normalized URL of a source, thus the SSH form, the
/// HTTPS form, and the `github:` shorthand of one repository all reach the
/// same pattern. Every row of the table names the pattern, the source URL as
/// a host writes it, and the expected result.
@Suite("Source pattern")
struct SourcePatternTests {
  /// One row of the match table.
  struct MatchCase: Sendable, CustomStringConvertible {
    /// The pattern under test.
    let pattern: SourcePattern

    /// The source URL, in one of the §5.1 forms.
    let sourceURL: String

    /// Whether the pattern matches the normalized form of ``sourceURL``.
    let matches: Bool

    /// Names the row, thus a failed test says which row broke.
    var description: String {
      let verb = matches ? "matches" : "does not match"
      return #"\#(pattern) \#(verb) "\#(sourceURL)""#
    }
  }

  /// The HTTPS URL that the exact pattern names.
  private static let httpsRepository = "https://github.com/acme/skills.git"

  /// The pattern kinds against the §5.1 URL forms.
  static let matchCases: [MatchCase] = exactCases + ownerCases + hostRegexCases + pathPrefixCases

  /// The rows of ``SourcePattern/exact(_:)``.
  private static let exactCases: [MatchCase] = [
    MatchCase(pattern: .exact(httpsRepository), sourceURL: httpsRepository, matches: true),
    // The shorthand expands to the same normalized URL.
    MatchCase(pattern: .exact(httpsRepository), sourceURL: "github:acme/skills", matches: true),
    // A trailing slash and an upper-case host both normalize away.
    MatchCase(pattern: .exact(httpsRepository), sourceURL: "https://GitHub.com/acme/skills.git/", matches: true),
    // The parser lowercases the scheme and the host but not the path,
    // thus a path in another letter case is another normalized URL.
    MatchCase(pattern: .exact(httpsRepository), sourceURL: "https://github.com/ACME/skills.git", matches: false),
    // The SSH form is a different normalized URL.
    MatchCase(pattern: .exact(httpsRepository), sourceURL: "git@github.com:acme/skills.git", matches: false),
    MatchCase(pattern: .exact(httpsRepository), sourceURL: "https://github.com/acme/other.git", matches: false),
  ]

  /// The rows of ``SourcePattern/owner(host:owner:)``.
  private static let ownerCases: [MatchCase] = [
    MatchCase(pattern: .owner(host: "github.com", owner: "acme"), sourceURL: httpsRepository, matches: true),
    MatchCase(
      pattern: .owner(host: "github.com", owner: "acme"), sourceURL: "git@github.com:acme/skills.git",
      matches: true),
    MatchCase(
      pattern: .owner(host: "github.com", owner: "acme"), sourceURL: "github:acme/skills", matches: true),
    // The host comparison is not case sensitive.
    MatchCase(
      pattern: .owner(host: "GitHub.com", owner: "acme"), sourceURL: httpsRepository, matches: true),
    // The owner comparison is case sensitive, because the parser keeps
    // the letter case of the path.
    MatchCase(
      pattern: .owner(host: "github.com", owner: "acme"), sourceURL: "github:ACME/skills", matches: false),
    // Another repository of the same owner still matches.
    MatchCase(
      pattern: .owner(host: "github.com", owner: "acme"), sourceURL: "github:acme/other", matches: true),
    MatchCase(
      pattern: .owner(host: "github.com", owner: "acme"), sourceURL: "github:other/skills", matches: false),
    MatchCase(
      pattern: .owner(host: "github.com", owner: "acme"),
      sourceURL: "https://gitlab.com/acme/skills.git", matches: false),
    MatchCase(
      pattern: .owner(host: "github.com", owner: "acme"), sourceURL: "file:///opt/skills", matches: false),
  ]

  /// The rows of ``SourcePattern/hostRegex(_:)``.
  private static let hostRegexCases: [MatchCase] = [
    MatchCase(
      pattern: .hostRegex(#"git\.[a-z]+\.example\.com"#),
      sourceURL: "https://git.team.example.com/acme/skills.git", matches: true),
    MatchCase(
      pattern: .hostRegex(#"git\.[a-z]+\.example\.com"#),
      sourceURL: "git@git.team.example.com:acme/skills.git", matches: true),
    MatchCase(
      pattern: .hostRegex(#"git\.[a-z]+\.example\.com"#), sourceURL: httpsRepository, matches: false),
    // The parser writes the host in lowercase, thus an expression in
    // lowercase reaches a source that names the host in upper case.
    MatchCase(
      pattern: .hostRegex(#"github\.com"#), sourceURL: "https://GitHub.com/acme/skills.git", matches: true),
    // For the same reason an expression in upper case matches no host.
    MatchCase(pattern: .hostRegex(#"GitHub\.com"#), sourceURL: httpsRepository, matches: false),
    // The whole host must match, thus a part of the name is not enough.
    MatchCase(pattern: .hostRegex("github"), sourceURL: httpsRepository, matches: false),
    // A local folder has no host.
    MatchCase(pattern: .hostRegex(".*"), sourceURL: "file:///opt/skills", matches: false),
    // A regex that does not compile matches nothing.
    MatchCase(pattern: .hostRegex("["), sourceURL: httpsRepository, matches: false),
  ]

  /// The rows of ``SourcePattern/pathPrefix(_:)``.
  private static let pathPrefixCases: [MatchCase] = [
    MatchCase(pattern: .pathPrefix("/opt/skills"), sourceURL: "file:///opt/skills", matches: true),
    MatchCase(pattern: .pathPrefix("/opt/skills"), sourceURL: "file:///opt/skills/team", matches: true),
    MatchCase(pattern: .pathPrefix("/opt/skills"), sourceURL: "file:///opt/skills/team.git", matches: true),
    // The parser keeps the letter case of the path, thus the comparison
    // is case sensitive.
    MatchCase(pattern: .pathPrefix("/opt/skills"), sourceURL: "file:///opt/Skills", matches: false),
    // The scheme is not case sensitive.
    MatchCase(pattern: .pathPrefix("/opt/skills"), sourceURL: "FILE:///opt/skills", matches: true),
    // A folder whose name only starts with the prefix is not under it.
    MatchCase(pattern: .pathPrefix("/opt/skills"), sourceURL: "file:///opt/skills-other", matches: false),
    MatchCase(pattern: .pathPrefix("/opt/skills"), sourceURL: "file:///opt", matches: false),
    // A remote source has no local path.
    MatchCase(pattern: .pathPrefix("/acme"), sourceURL: httpsRepository, matches: false),
  ]

  @Test(arguments: matchCases) func thePatternMatchesTheNormalizedURLOfTheSource(_ row: MatchCase) throws {
    let location = try MarketplaceLocation(source: MarketplaceSource(row.sourceURL))

    #expect(row.pattern.matches(normalizedURL: location.normalizedURL) == row.matches)
  }

  @Test func eachPatternKindNamesItselfInOneLine() {
    #expect(String(describing: SourcePattern.exact(Self.httpsRepository)).contains(Self.httpsRepository))
    #expect(String(describing: SourcePattern.owner(host: "github.com", owner: "acme")).contains("acme"))
    #expect(String(describing: SourcePattern.hostRegex("git.*")).contains("git.*"))
    #expect(String(describing: SourcePattern.pathPrefix("/opt")).contains("/opt"))
  }

  @Test(arguments: [
    SourcePattern.exact(httpsRepository),
    SourcePattern.owner(host: "github.com", owner: "acme"),
    SourcePattern.hostRegex("git.*"),
    SourcePattern.pathPrefix("/opt/skills"),
  ]) func aPatternSurvivesACodableRoundTrip(_ pattern: SourcePattern) throws {
    let encoded = try JSONEncoder().encode(pattern)

    #expect(try JSONDecoder().decode(SourcePattern.self, from: encoded) == pattern)
  }
}
