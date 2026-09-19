import Foundation
import Testing

@testable import Marketplace

/// Proves the origin check and the one-time rule of ``CredentialGate``
/// (marketplace.md §5.1).
///
/// The gate is a pure value, thus the suite needs no server and no network.
@Suite("Credential gate")
struct CredentialGateTests {
  /// The HTTPS source that each gate serves.
  private static let sourceURL = "https://git.example.com/owner/skills.git"

  /// A request that libgit2 makes to the origin of ``sourceURL``.
  private static let requestURL = "https://git.example.com/owner/skills.git/info/refs?service=git-upload-pack"

  /// The credential that the host gives. The values are plain fixture text.
  private static let credential = MarketplaceCredential(username: "fixture-user", token: "fixture-token")

  // MARK: - The one-time rule

  @Test func aRequestFromTheSourceOriginGetsTheCredential() {
    var gate = CredentialGate(sourceURL: Self.sourceURL, credential: Self.credential)

    #expect(gate.credential(forRequestURL: Self.requestURL) == Self.credential)
    #expect(!gate.hasRefused)
  }

  @Test func aSecondRequestIsRefused() {
    var gate = CredentialGate(sourceURL: Self.sourceURL, credential: Self.credential)
    _ = gate.credential(forRequestURL: Self.requestURL)

    #expect(gate.credential(forRequestURL: Self.requestURL) == nil)
    #expect(gate.hasRefused)
  }

  @Test func aGateWithNoCredentialRefusesTheFirstRequest() {
    var gate = CredentialGate(sourceURL: Self.sourceURL, credential: nil)

    #expect(gate.credential(forRequestURL: Self.requestURL) == nil)
    #expect(gate.hasRefused)
  }

  // MARK: - The origin check

  @Test(arguments: [
    "https://other.example.com/owner/skills.git",
    "http://git.example.com/owner/skills.git",
    "https://git.example.com:8443/owner/skills.git",
  ])
  func aRequestFromAnotherOriginIsRefused(requestURL: String) {
    var gate = CredentialGate(sourceURL: Self.sourceURL, credential: Self.credential)

    #expect(gate.credential(forRequestURL: requestURL) == nil)
    #expect(gate.hasRefused)
  }

  @Test func aRefusedRequestFromAnotherOriginDoesNotUseTheCredential() {
    var gate = CredentialGate(sourceURL: Self.sourceURL, credential: Self.credential)
    _ = gate.credential(forRequestURL: "https://other.example.com/owner/skills.git")

    #expect(gate.credential(forRequestURL: Self.requestURL) == Self.credential)
  }

  @Test func theDefaultPortWrittenOutIsTheSameOrigin() {
    var gate = CredentialGate(sourceURL: Self.sourceURL, credential: Self.credential)

    #expect(gate.credential(forRequestURL: "https://git.example.com:443/owner/skills.git") == Self.credential)
  }

  @Test func theSchemeAndTheHostAreComparedWithoutLetterCase() {
    var gate = CredentialGate(sourceURL: Self.sourceURL, credential: Self.credential)

    #expect(gate.credential(forRequestURL: "HTTPS://Git.Example.COM/owner/skills.git") == Self.credential)
  }

  // MARK: - Resolution before the libgit2 call

  @Test func anHTTPSSourceAsksTheProviderOneTimeWithTheSourceURL() async throws {
    let recorder = CredentialRequestRecorder()

    var gate = await CredentialGate.resolved(
      forSourceURL: Self.sourceURL, credentials: recorder.provider(giving: Self.credential))

    #expect(await recorder.requestedURLs == [try #require(URL(string: Self.sourceURL))])
    #expect(gate.credential(forRequestURL: Self.requestURL) == Self.credential)
  }

  @Test(arguments: ["git@github.com:owner/skills.git", "ssh://git@github.com/owner/skills.git"])
  func anSSHSourceNeverAsks(sourceURL: String) async {
    let recorder = CredentialRequestRecorder()

    var gate = await CredentialGate.resolved(
      forSourceURL: sourceURL, credentials: recorder.provider(giving: Self.credential))

    #expect(await recorder.requestedURLs.isEmpty)
    #expect(gate.credential(forRequestURL: sourceURL) == nil)
  }

  @Test func aPlainHTTPSourceNeverAsks() async {
    let recorder = CredentialRequestRecorder()
    let sourceURL = "http://git.example.com/owner/skills.git"

    var gate = await CredentialGate.resolved(
      forSourceURL: sourceURL, credentials: recorder.provider(giving: Self.credential))

    #expect(await recorder.requestedURLs.isEmpty)
    #expect(gate.credential(forRequestURL: sourceURL) == nil)
  }

  @Test func noProviderGivesNoCredential() async {
    var gate = await CredentialGate.resolved(forSourceURL: Self.sourceURL, credentials: nil)

    #expect(gate.credential(forRequestURL: Self.requestURL) == nil)
  }

  // MARK: - Redaction

  @Test func theTextOfACredentialShowsNeitherTheUserNameNorTheToken() {
    let texts = [String(describing: Self.credential), String(reflecting: Self.credential)]

    #expect(texts.allSatisfy { !$0.contains(Self.credential.token) && !$0.contains(Self.credential.username) })
  }

  @Test func theMirrorOfACredentialShowsNoChild() {
    let mirror = Mirror(reflecting: Self.credential)

    #expect(mirror.children.isEmpty)
  }
}
