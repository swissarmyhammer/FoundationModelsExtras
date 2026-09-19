import FixtureSupport
import Foundation
import Marketplace
import MarketplaceFixtures
import Testing

/// Proves the counting double that the store tests of `FoundationModelsSkills`
/// inject through the public ``GitTransport``: it counts each call, records
/// the credential of each fetch, and does the real libgit2 work.
///
/// The suite imports `Marketplace` without `@testable`, thus it also proves
/// that the double and the transport protocol are public.
@Suite("Recording git transport")
struct RecordingGitTransportTests {
  /// The credential that a fetch provider gives. The values are plain
  /// fixture text.
  private static let credential = MarketplaceCredential(username: "fixture-user", token: "fixture-token")

  @Test func aRemoteHeadCallIsCountedAndAnswered() async throws {
    let fixture = try GitFixtureRepository()
    let tip = try fixture.commit(files: ["README.md": .file("first")])
    let transport = RecordingGitTransport()

    let head = try await transport.remoteHead(url: fixture.url, ref: "main", credentials: nil)

    #expect(head == tip)
    #expect(await transport.remoteHeadCount == 1)
    #expect(await transport.fetchCount == 0)
  }

  @Test func eachFetchIsCountedWithTheCredentialThatItsProviderGives() async throws {
    let fixture = try GitFixtureRepository()
    let tip = try fixture.commit(files: ["README.md": .file("first")])
    let destination = try TemporaryDirectory.make().appendingPathComponent("repo.git", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
    let transport = RecordingGitTransport()
    let fetches = 2

    let first = try await transport.fetch(
      url: fixture.url, revision: "main", intoBareRepository: destination, credentials: nil)
    let second = try await transport.fetch(
      url: fixture.url, revision: "main", intoBareRepository: destination, credentials: { _ in Self.credential })

    #expect([first, second] == [tip, tip])
    #expect(await transport.fetchCount == fetches)
    #expect(await transport.fetchCredentials == [nil, Self.credential])
  }
}
