import Foundation
import Testing

@testable import Marketplace

/// Proves that the allowlist and the blocklist of ``MarketplacePolicy`` decide
/// with no store and no I/O (marketplace.md §6.7 and §10 item 2), that the
/// policy reads `SKILLS_MARKETPLACE_AUTOUPDATE` from its environment
/// (marketplace.md §8.3), and that a new policy has the documented defaults.
///
/// Every value here is pure: no test makes a cache folder or opens a
/// connection.
@Suite("Marketplace policy values")
struct MarketplacePolicyValueTests {
  /// The normalized URL of the source under test.
  private static let sourceURL = "https://github.com/acme/skills.git"

  /// The normalized URL of a second repository of the same owner.
  private static let siblingURL = "https://github.com/acme/other.git"

  /// The exact pattern that names ``sourceURL``.
  private static let exactPattern = SourcePattern.exact(sourceURL)

  /// The owner pattern that names ``sourceURL`` and ``siblingURL``.
  private static let ownerPattern = SourcePattern.owner(host: "github.com", owner: "acme")

  /// An owner pattern that names no source of this suite.
  private static let otherOwner = SourcePattern.owner(host: "github.com", owner: "other")

  /// An environment that stops every automatic update.
  private static let updatesOff = [MarketplacePolicy.automaticUpdateVariable: "0"]

  /// Environments that stop no automatic update: no variable, a value that
  /// is not `0`, and an empty value.
  private static let updatesOn: [[String: String]] = [
    [:],
    [MarketplacePolicy.automaticUpdateVariable: "1"],
    [MarketplacePolicy.automaticUpdateVariable: ""],
  ]

  /// The number of bytes in one mebibyte.
  private static let bytesInOneMebibyte = 1024 * 1024

  /// The number of mebibytes of the default snapshot size limit.
  private static let defaultMebibytes = 64

  /// The default snapshot file count limit.
  private static let defaultFileCount = 5_000

  /// A snapshot size limit that is not the default.
  private static let smallByteLimit = 4_096

  /// A snapshot file count limit that is not the default.
  private static let smallFileLimit = 12

  // MARK: - The blocklist

  @Test func aBlockedSourceIsRefusedByThePatternThatNamesIt() {
    let policy = MarketplacePolicy(blockedSources: [Self.exactPattern])

    #expect(policy.refusal(forNormalizedURL: Self.sourceURL) == .blocked(Self.exactPattern))
  }

  @Test func anOwnerPatternInTheBlocklistRefusesEveryRepositoryOfThatOwner() {
    let policy = MarketplacePolicy(blockedSources: [Self.ownerPattern])

    #expect(policy.refusal(forNormalizedURL: Self.siblingURL) == .blocked(Self.ownerPattern))
  }

  @Test func aBlocklistThatNamesNoSourceRefusesNothing() {
    let policy = MarketplacePolicy(blockedSources: [Self.otherOwner])

    #expect(policy.refusal(forNormalizedURL: Self.sourceURL) == nil)
  }

  // MARK: - The allowlist

  @Test func anEmptyAllowlistRefusesEverySource() {
    let policy = MarketplacePolicy(allowedSources: [])

    #expect(policy.refusal(forNormalizedURL: Self.sourceURL) == .notAllowed)
  }

  @Test func anAllowlistThatNoEntryMatchesRefusesTheSource() {
    let policy = MarketplacePolicy(allowedSources: [Self.otherOwner])

    #expect(policy.refusal(forNormalizedURL: Self.sourceURL) == .notAllowed)
  }

  @Test func anAllowedSourceIsNotRefused() {
    let policy = MarketplacePolicy(allowedSources: [Self.exactPattern])

    #expect(policy.refusal(forNormalizedURL: Self.sourceURL) == nil)
  }

  // MARK: - Both lists

  @Test func theBlocklistWinsOverTheAllowlist() {
    let policy = MarketplacePolicy(allowedSources: [Self.exactPattern], blockedSources: [Self.exactPattern])

    #expect(policy.refusal(forNormalizedURL: Self.sourceURL) == .blocked(Self.exactPattern))
  }

  @Test func aPolicyWithNoListRefusesNothing() {
    let policy = MarketplacePolicy(environment: [:])

    #expect(policy.refusal(forNormalizedURL: Self.sourceURL) == nil)
  }

  // MARK: - Automatic updates

  @Test func anEnvironmentWithTheVariableAtZeroStopsAutomaticUpdates() {
    #expect(!MarketplacePolicy.automaticUpdatesAllowed(environment: Self.updatesOff))
  }

  @Test(arguments: updatesOn)
  func anyOtherEnvironmentAllowsAutomaticUpdates(environment: [String: String]) {
    #expect(MarketplacePolicy.automaticUpdatesAllowed(environment: environment))
  }

  @Test func thePolicyReadsTheVariableFromItsEnvironment() {
    let policy = MarketplacePolicy(autoUpdate: true, environment: Self.updatesOff)

    #expect(!policy.autoUpdate)
  }

  @Test func aPolicyWithAutoUpdateOffStaysOffWhenTheEnvironmentAllowsUpdates() {
    let policy = MarketplacePolicy(autoUpdate: false, environment: [:])

    #expect(!policy.autoUpdate)
  }

  // MARK: - Defaults

  @Test func aNewPolicyHasTheDocumentedDefaults() {
    let policy = MarketplacePolicy(environment: [:])

    #expect(policy.snapshotLimits == SnapshotLimits())
    #expect(policy.allowedSources == nil)
    #expect(policy.blockedSources.isEmpty)
    #expect(policy.credentials == nil)
    #expect(policy.checkInterval == nil)
    #expect(policy.autoUpdate)
    #expect(!policy.checkOnly)
    #expect(policy.applyUpdates == .immediately)
    #expect(policy.fetchTimeout == nil)
  }

  @Test func theDefaultSnapshotLimitsAre64MebibytesAnd5000Files() {
    let limits = SnapshotLimits()

    #expect(limits.maxBytes == Self.defaultMebibytes * Self.bytesInOneMebibyte)
    #expect(limits.maxFiles == Self.defaultFileCount)
  }

  @Test func aHostSetsItsOwnSnapshotLimits() {
    let limits = SnapshotLimits(maxBytes: Self.smallByteLimit, maxFiles: Self.smallFileLimit)

    #expect(limits.maxBytes == Self.smallByteLimit)
    #expect(limits.maxFiles == Self.smallFileLimit)
  }
}
