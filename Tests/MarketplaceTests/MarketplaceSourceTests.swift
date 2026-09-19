import Foundation
import Testing

@testable import Marketplace

/// Proves the marketplace source values, the §5.1 URL forms, and the §5.3
/// identity rules (marketplace.md §5.1, §5.3, and §6.2).
///
/// Every value here is pure: no test reads the disk or the network.
@Suite("Marketplace source")
struct MarketplaceSourceTests {
  /// The SSH form of the swissarmyhammer marketplace.
  private static let sshURL = "git@github.com:swissarmyhammer/skills.git"

  /// The HTTPS form of the swissarmyhammer marketplace.
  private static let httpsURL = "https://github.com/swissarmyhammer/skills.git"

  /// A 40-hex commit SHA for the pin tests.
  private static let pinnedSHA = "0123456789abcdef0123456789abcdef01234567"

  /// A local marketplace folder.
  private static let localFolder = URL(fileURLWithPath: "/Users/me/skills", isDirectory: true)

  // MARK: - URL forms

  /// Each §5.1 form with the location that it gives.
  private static let validForms: [(String, MarketplaceLocation)] = [
    (sshURL, .git(url: sshURL, ref: nil)),
    ("git@GitHub.COM:swissarmyhammer/skills.git/", .git(url: sshURL, ref: nil)),
    (httpsURL, .git(url: httpsURL, ref: nil)),
    ("https://GitHub.COM/swissarmyhammer/skills.git/", .git(url: httpsURL, ref: nil)),
    ("github:swissarmyhammer/skills", .git(url: httpsURL, ref: nil)),
    ("github:swissarmyhammer/skills.git", .git(url: httpsURL, ref: nil)),
    ("\(httpsURL)#v1.2.0", .git(url: httpsURL, ref: "v1.2.0")),
    ("\(sshURL)#main", .git(url: sshURL, ref: "main")),
    ("github:swissarmyhammer/skills#stable", .git(url: httpsURL, ref: "stable")),
    ("file:///Users/me/skills", .local(localFolder)),
    ("file:///Users/me/skills/", .local(localFolder)),
    ("HTTPS://github.com/swissarmyhammer/skills.git", .git(url: httpsURL, ref: nil)),
    ("GitHub:swissarmyhammer/skills", .git(url: httpsURL, ref: nil)),
    ("FILE:///Users/me/skills", .local(localFolder)),
  ]

  @Test(arguments: validForms)
  func eachURLFormParsesToItsLocation(url: String, expected: MarketplaceLocation) throws {
    let location = try MarketplaceLocation(source: MarketplaceSource(url))

    #expect(location == expected)
  }

  /// Each bad input with the error that it gives.
  private static let invalidForms: [(String, MarketplaceSourceError)] = [
    ("", .emptyURL),
    ("skills", .unsupportedForm),
    ("ftp://github.com/swissarmyhammer/skills.git", .unsupportedForm),
    ("https:///skills.git", .missingHost),
    ("git@:swissarmyhammer/skills.git", .missingHost),
    ("https://github.com/", .missingRepository),
    ("git@github.com:", .missingRepository),
    ("https://github.com/.git", .missingRepository),
    ("https://github.com/swissarmyhammer/skills", .missingGitSuffix),
    ("git@github.com:swissarmyhammer/skills", .missingGitSuffix),
    ("https://me:secret@github.com/swissarmyhammer/skills.git", .credentialsInURL),
    ("github:swissarmyhammer", .invalidShorthand),
    ("github:swissarmyhammer/skills/extra", .invalidShorthand),
    ("github:/skills", .invalidShorthand),
    ("\(httpsURL)#", .emptyRef),
    ("file://example.com/Users/me/skills", .invalidLocalPath),
    ("file://", .invalidLocalPath),
    ("file:///Users/me/skills#main", .refOnLocalFolder),
  ]

  @Test(arguments: invalidForms)
  func aBadURLThrowsItsError(url: String, expected: MarketplaceSourceError) {
    #expect(throws: expected) {
      try MarketplaceLocation(source: MarketplaceSource(url))
    }
  }

  @Test func theRefFieldWinsOverTheRefSuffix() throws {
    let source = MarketplaceSource("\(Self.httpsURL)#v1.0.0", ref: "v2.0.0")

    #expect(try MarketplaceLocation(source: source) == .git(url: Self.httpsURL, ref: "v2.0.0"))
  }

  @Test func theSHAWinsOverTheRef() throws {
    let source = MarketplaceSource("\(Self.httpsURL)#v1.0.0", ref: "main", sha: Self.pinnedSHA)

    #expect(try MarketplaceLocation(source: source) == .git(url: Self.httpsURL, ref: Self.pinnedSHA))
  }

  @Test func aSourceWithASHAIsPinned() {
    #expect(MarketplaceSource(Self.httpsURL, sha: Self.pinnedSHA).isPinned)
  }

  @Test func aSourceWithARefAndNoSHAIsNotPinned() {
    #expect(!MarketplaceSource(Self.httpsURL, ref: "main").isPinned)
  }

  @Test(arguments: [
    MarketplaceSource("file:///Users/me/skills", ref: "main"),
    MarketplaceSource("file:///Users/me/skills", sha: pinnedSHA),
  ])
  func aRefOrASHAOnALocalFolderThrows(source: MarketplaceSource) {
    #expect(throws: MarketplaceSourceError.refOnLocalFolder) {
      try MarketplaceLocation(source: source)
    }
  }

  // MARK: - Normalized URL

  @Test func theNormalizedURLOfAGitLocationIsItsURLWithoutTheRef() throws {
    let location = try MarketplaceLocation(source: MarketplaceSource("https://GitHub.com/acme/skills.git/#main"))

    #expect(location.normalizedURL == "https://github.com/acme/skills.git")
  }

  @Test func theNormalizedURLOfALocalFolderIsAFileURLWithNoTrailingSlash() throws {
    let location = try MarketplaceLocation(source: MarketplaceSource("file:///Users/me/skills/"))

    #expect(location.normalizedURL == "file:///Users/me/skills")
  }

  // MARK: - Pre-fetch key

  @Test(arguments: [
    (sshURL, "skills"),
    (httpsURL, "skills"),
    ("github:acme/team-skills", "team-skills"),
    ("file:///Users/me/local-skills", "local-skills"),
  ])
  func thePreFetchKeyIsTheRepositoryNameWithoutTheGitSuffix(url: String, expected: String) throws {
    #expect(try MarketplaceIdentity.preFetchKey(for: MarketplaceSource(url)) == expected)
  }

  @Test func theAliasWinsOverTheRepositoryNameForThePreFetchKey() throws {
    let source = MarketplaceSource(Self.httpsURL, alias: "sah")

    #expect(try MarketplaceIdentity.preFetchKey(for: source) == "sah")
  }

  @Test(arguments: ["", "team/skills", "../skills"])
  func anAliasThatIsNotAFolderNameThrows(alias: String) {
    #expect(throws: MarketplaceSourceError.unusableKey(alias)) {
      try MarketplaceIdentity.preFetchKey(for: MarketplaceSource(Self.httpsURL, alias: alias))
    }
  }

  // MARK: - Cache folder name

  @Test func theCacheFolderNameIsTheKeyAndTheFirstEightHexOfTheURLHash() {
    // printf %s https://github.com/swissarmyhammer/skills.git | shasum -a 256
    // gives d4fdad4eaa0dc5779e7078f1eb70350864733ab2ad42ad1f0b626f50da4680ff.
    #expect(MarketplaceIdentity.cacheFolderName(key: "skills", normalizedURL: Self.httpsURL) == "skills-d4fdad4e")
  }

  @Test func theCacheFolderNameIsStableForOneURL() {
    let first = MarketplaceIdentity.cacheFolderName(key: "skills", normalizedURL: Self.sshURL)
    let second = MarketplaceIdentity.cacheFolderName(key: "skills", normalizedURL: Self.sshURL)

    #expect(first == second)
  }

  @Test func theCacheFolderNameIsDifferentForTwoURLs() {
    let ssh = MarketplaceIdentity.cacheFolderName(key: "skills", normalizedURL: Self.sshURL)
    let https = MarketplaceIdentity.cacheFolderName(key: "skills", normalizedURL: Self.httpsURL)

    // printf %s git@github.com:swissarmyhammer/skills.git | shasum -a 256
    // gives 7f8050d3f8415cbc4d6f60bc189166ef284bbd98a376fd47915ecca6e926fca8.
    #expect(ssh == "skills-7f8050d3")
    #expect(ssh != https)
  }

  // MARK: - Validation

  @Test func aListWithADuplicatePreFetchKeyGivesOneErrorDiagnostic() {
    let sources = [
      MarketplaceSource(Self.sshURL),
      MarketplaceSource("github:acme/tools"),
      MarketplaceSource("github:acme/skills"),
    ]

    let diagnostics = MarketplaceIdentity.validate(sources)

    #expect(diagnostics.count == 1)
    #expect(diagnostics.first?.severity == .error)
    #expect(diagnostics.first?.marketplaceID == "skills")
    #expect(diagnostics.first?.message.contains(Self.sshURL) == true)
    #expect(diagnostics.first?.message.contains("github:acme/skills") == true)
  }

  @Test func anAliasRemovesTheDuplicateKey() {
    let sources = [
      MarketplaceSource(Self.sshURL),
      MarketplaceSource("github:acme/skills", alias: "acme"),
    ]

    #expect(MarketplaceIdentity.validate(sources).isEmpty)
  }

  @Test func aSourceWithABadURLGivesAnErrorDiagnostic() {
    let diagnostics = MarketplaceIdentity.validate([MarketplaceSource("skills", alias: "bad")])

    #expect(diagnostics.count == 1)
    #expect(diagnostics.first?.severity == .error)
    #expect(diagnostics.first?.marketplaceID == "bad")
    #expect(diagnostics.first?.message.contains(MarketplaceSourceError.unsupportedForm.description) == true)
  }

  // MARK: - Defaults

  @Test func aNewSourceHasTheDefaultSelectionAndAutoUpdate() {
    let source = MarketplaceSource(Self.httpsURL)

    #expect(source.select == .all)
    #expect(source.autoUpdate)
  }

  // MARK: - Codable

  @Test func aSourceWithEveryFieldSurvivesACodableRoundTrip() throws {
    let source = MarketplaceSource(
      Self.httpsURL,
      ref: "stable",
      sha: Self.pinnedSHA,
      path: "catalog",
      alias: "sah",
      select: .skills(["plan", "review"]),
      autoUpdate: false)

    #expect(try roundTrip(source) == source)
  }

  @Test(arguments: [SkillSelection.all, .plugins(["sah", "extras"]), .skills(["plan"])])
  func eachSkillSelectionSurvivesACodableRoundTrip(selection: SkillSelection) throws {
    #expect(try roundTrip(selection) == selection)
  }

  @Test func aSourceWithOnlyAURLDecodesWithTheDefaults() throws {
    let decoded = try decode(MarketplaceSource.self, from: #"{"url": "github:acme/skills"}"#)

    #expect(decoded == MarketplaceSource("github:acme/skills"))
  }

  @Test(arguments: [
    (#""all""#, SkillSelection.all),
    (#"{"plugins": ["sah"]}"#, .plugins(["sah"])),
    (#"{"skills": ["plan", "review"]}"#, .skills(["plan", "review"])),
  ])
  func aSkillSelectionDecodesFromItsConfigurationForm(json: String, expected: SkillSelection) throws {
    #expect(try decode(SkillSelection.self, from: json) == expected)
  }

  @Test(arguments: [#""some""#, #"{"teams": ["a"]}"#, #"{"plugins": ["a"], "skills": ["b"]}"#])
  func anUnknownSkillSelectionDoesNotDecode(json: String) {
    #expect(throws: DecodingError.self) {
      try decode(SkillSelection.self, from: json)
    }
  }

  @Test func aCaseVariantOfAllDoesNotDecode() {
    #expect(throws: DecodingError.self) {
      try decode(SkillSelection.self, from: #""All""#)
    }
  }

  // MARK: - Diagnostic

  @Test func aDiagnosticWithAMarketplaceIDRendersTheIDInOneLine() {
    let diagnostic = MarketplaceDiagnostic(severity: .error, marketplaceID: "skills", message: "The key is used two times.")

    #expect(diagnostic.description == "[error] skills: The key is used two times.")
  }

  @Test func aDiagnosticWithNoMarketplaceIDRendersOnlyTheMessage() {
    let diagnostic = MarketplaceDiagnostic(severity: .warning, marketplaceID: nil, message: "The list is empty.")

    #expect(diagnostic.description == "[warning] The list is empty.")
  }

  // MARK: - Helpers

  /// Encodes `value` to JSON and decodes it again.
  ///
  /// - Parameter value: The value to send through the round trip.
  /// - Returns: The decoded copy.
  private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
  }

  /// Decodes a value from JSON text.
  ///
  /// - Parameters:
  ///   - type: The type to decode.
  ///   - json: The JSON text.
  /// - Returns: The decoded value.
  private func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
    try JSONDecoder().decode(type, from: Data(json.utf8))
  }
}
