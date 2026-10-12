import FixtureSupport
import Foundation
import Testing

@testable import Marketplace

/// ``MarketplaceTelemetry`` holds each telemetry name of the marketplace
/// target, and no other source file of the target writes one.
@Suite("Marketplace telemetry: one vocabulary file holds each name of the target")
struct MarketplaceTelemetryTests {
  /// The folder of the sources of the target, relative to the package root.
  private static let sourcesPath = "Sources/Marketplace"

  /// The file name of the vocabulary file.
  private static let vocabularyFileName = "MarketplaceTelemetry.swift"

  /// The string literals that only the vocabulary file may hold: the start of
  /// each span name and each metric name, and each attribute key, dimension
  /// key and log metadata key of the target.
  private static let telemetryLiterals = [
    "\"Marketplace.",
    "\"marketplace.id\"",
    "\"pass.kind\"",
    "\"pass.outcome\"",
    "\"git.outcome\"",
  ]

  /// The display id of the events of the outcome test.
  private static let sampleID = "fixture"

  /// The commit of the events of the outcome test. The value is any object
  /// name: the outcome reads the case of an event, never its commit.
  private static let sampleCommit = "0123456789abcdef0123456789abcdef01234567"

  @Test("each span name and each metric name starts with the module name")
  func eachNameStartsWithTheModuleName() {
    let names = [
      MarketplaceTelemetry.SpanName.pass,
      MarketplaceTelemetry.SpanName.checkHead,
      MarketplaceTelemetry.SpanName.sync,
      MarketplaceTelemetry.SpanName.fetch,
      MarketplaceTelemetry.SpanName.remoteHead,
      MarketplaceTelemetry.SpanName.materialize,
      MarketplaceTelemetry.MetricName.passes,
      MarketplaceTelemetry.MetricName.fetchDuration,
      MarketplaceTelemetry.MetricName.remoteHeadDuration,
    ]

    #expect(names.filter { !$0.hasPrefix(MarketplaceTelemetryExpectations.namePrefix) } == [])
    #expect(Set(names).count == names.count)
  }

  @Test("the logger has the module name as its label")
  func theLoggerHasTheModuleLabel() {
    #expect(MarketplaceTelemetry.logLabel == "Marketplace")
    #expect(MarketplaceTelemetry.makeLogger().label == MarketplaceTelemetry.logLabel)
  }

  @Test("each key has its dotted name, and a dimension or metadata key is the attribute key")
  func eachKeyHasItsDottedName() {
    #expect(MarketplaceTelemetry.AttributeKey.marketplaceID == "marketplace.id")
    #expect(MarketplaceTelemetry.AttributeKey.passKind == "pass.kind")
    #expect(MarketplaceTelemetry.AttributeKey.passOutcome == "pass.outcome")
    #expect(MarketplaceTelemetry.DimensionKey.gitOutcome == "git.outcome")
    #expect(MarketplaceTelemetry.DimensionKey.marketplaceID == MarketplaceTelemetry.AttributeKey.marketplaceID)
    #expect(MarketplaceTelemetry.DimensionKey.passKind == MarketplaceTelemetry.AttributeKey.passKind)
    #expect(MarketplaceTelemetry.DimensionKey.passOutcome == MarketplaceTelemetry.AttributeKey.passOutcome)
    #expect(MarketplaceTelemetry.LogMetadataKey.marketplaceID == MarketplaceTelemetry.AttributeKey.marketplaceID)
  }

  @Test("the pass outcome of each event is its one bounded value")
  func eachEventGivesItsPassOutcome() {
    let id = Self.sampleID
    let sha = Self.sampleCommit
    let outcomes: [(MarketplaceEvent?, MarketplacePassOutcome)] = [
      (nil, .upToDate),
      (.checked(id: id, current: sha, latest: sha), .upToDate),
      (.updateAvailable(id: id, from: nil, to: sha), .updateAvailable),
      (.updated(id: id, from: nil, to: sha), .updated),
      (.failed(id: id, error: "qz-error-text", keptVersion: nil), .failed),
    ]

    for (event, expected) in outcomes {
      #expect(MarketplaceTelemetry.passOutcome(of: event) == expected)
    }
    #expect(MarketplacePassOutcome.allCases.map(\.rawValue) == ["up_to_date", "updated", "update_available", "failed"])
  }

  @Test("no source file of the target but the vocabulary file holds a telemetry name")
  func onlyTheVocabularyFileHoldsATelemetryName() throws {
    let root = FixtureFile.url(Self.sourcesPath)
    let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    let others = files.filter { $0.lastPathComponent != Self.vocabularyFileName }

    #expect(others.count + MarketplaceTelemetryExpectations.one == files.count)
    let offenders = try others.filter { file in
      let text = try String(contentsOf: file, encoding: .utf8)
      return Self.telemetryLiterals.contains { text.contains($0) }
    }
    #expect(offenders.map(\.lastPathComponent) == [])
  }
}
