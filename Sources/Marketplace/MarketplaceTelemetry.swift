import FoundationModelsExtras
import Logging
import Metrics
import Tracing

/// The telemetry vocabulary of the marketplace target: the span names, the
/// attribute keys, the metric names, the dimension keys and the log metadata
/// keys, and the helpers that open the spans and record the metrics.
///
/// The target keeps all of its telemetry names in this one file. No other
/// source file of the target writes a telemetry name as a string literal.
/// Each span name, the logger label and each metric name start with the
/// module name.
///
/// The target uses the swift-log, swift-metrics and swift-distributed-tracing
/// APIs only, and it bootstraps no backend. The executables of the family
/// bootstrap the backend. Until one does, each span and each metric does
/// nothing.
///
/// The content-safety rule: a span attribute, a log metadata value and a
/// metric dimension carry the display id of a marketplace and bounded values
/// only. They never carry a URL, a credential, a ref that a user typed, a
/// path, or the text of an error, because each record leaves the process
/// through the telemetry backend of the host. The text of
/// ``MarketplaceEvent/failed(id:error:keptVersion:)`` is the description of
/// an error, and that description can hold a URL or a ref. Thus a failed call
/// records only its `error.type`, which ``TracedCall`` writes.
enum MarketplaceTelemetry {
  /// The label of each logger of the target.
  static let logLabel = "Marketplace"

  /// The span names of the target.
  enum SpanName {
    /// The span of one pass over one marketplace: a check or an update.
    static let pass = "Marketplace.pass"

    /// The span of the head check of a check pass: the read of the remote
    /// head and the report of it.
    static let checkHead = "Marketplace.check_head"

    /// The span of the sync of an update pass: the writer lock, the read of
    /// the remote head, the fetch, the materialize step and the install.
    static let sync = "Marketplace.sync"

    /// The span of one fetch of a commit from the remote.
    static let fetch = "Marketplace.fetch"

    /// The span of one read of the remote head.
    static let remoteHead = "Marketplace.remote_head"

    /// The span of the materialize step: the scan of the fetched tree and the
    /// write of the staged snapshot.
    static let materialize = "Marketplace.materialize"
  }

  /// The attribute keys of the spans of the target.
  enum AttributeKey {
    /// The display id of the marketplace: the alias of the source, else the
    /// repository name. It is never the URL of the source.
    static let marketplaceID = "marketplace.id"

    /// The ``MarketplacePassKind`` of a pass.
    static let passKind = "pass.kind"

    /// The ``MarketplacePassOutcome`` of a pass.
    static let passOutcome = "pass.outcome"
  }

  /// The metric names of the target.
  enum MetricName {
    /// The counter that counts each pass, with the ``MarketplacePassOutcome``
    /// of the pass.
    static let passes = "Marketplace.passes"

    /// The timer that records the duration of each fetch, with the
    /// ``MarketplaceCallOutcome`` of the fetch.
    static let fetchDuration = "Marketplace.fetch.duration"

    /// The timer that records the duration of each read of the remote head,
    /// with the ``MarketplaceCallOutcome`` of the read.
    static let remoteHeadDuration = "Marketplace.remote_head.duration"

    /// The timer that records the duration of each install of a snapshot
    /// into the cache, with the ``MarketplaceCallOutcome`` of the install.
    static let installDuration = "Marketplace.install.duration"

    /// The counter that counts each writer lock that the cache could not
    /// take, because another writer held the folder of the marketplace. The
    /// lock never waits, thus the counter counts conflicts and no timer
    /// records a wait.
    static let writerLockConflicts = "Marketplace.writer_lock.conflicts"

    /// The counter that counts each snapshot that the cleanup of the cache
    /// deleted.
    static let removedSnapshots = "Marketplace.snapshots.removed"
  }

  /// The dimension keys of the metrics of the target.
  enum DimensionKey {
    /// The display id of the marketplace. It has the same key as the span
    /// attribute. The host names each marketplace in its source list, thus
    /// the dimension has a bounded cardinality.
    static let marketplaceID = AttributeKey.marketplaceID

    /// The ``MarketplacePassKind`` of a pass. It has the same key as the span
    /// attribute.
    static let passKind = AttributeKey.passKind

    /// The ``MarketplacePassOutcome`` of a pass. It has the same key as the
    /// span attribute.
    static let passOutcome = AttributeKey.passOutcome

    /// The ``MarketplaceCallOutcome`` of a fetch or of a read of the remote
    /// head.
    static let gitOutcome = "git.outcome"

    /// The ``MarketplaceCallOutcome`` of an install of a snapshot.
    static let installOutcome = "install.outcome"
  }

  /// The metadata keys of the log records of the target.
  enum LogMetadataKey {
    /// The display id of the marketplace. It has the same key as the span
    /// attribute.
    static let marketplaceID = AttributeKey.marketplaceID
  }

  /// Makes a logger with the label of the target.
  ///
  /// Make the logger at call time, not in a stored value. A logger keeps the
  /// handler of the time that it was made.
  ///
  /// - Returns: A logger that writes through the logging backend of the
  ///   host.
  static func makeLogger() -> Logger {
    Logger(label: logLabel)
  }

  /// Gives the bounded outcome of a pass from the event that the pass gave.
  ///
  /// The outcome reads the case of the event only, never its text.
  ///
  /// - Parameter event: The event of the pass, or `nil` when nothing changed.
  /// - Returns: The outcome of the pass.
  static func passOutcome(of event: MarketplaceEvent?) -> MarketplacePassOutcome {
    switch event {
    case nil, .checked: .upToDate
    case .updateAvailable: .updateAvailable
    case .updated: .updated
    case .failed: .failed
    }
  }

  /// Runs one pass in one pass span, and counts the pass with its outcome.
  ///
  /// The span gets the display id and the kind before `body` runs, and the
  /// outcome when `body` returns. A failed pass also gets the error status.
  /// The child span that threw holds the `error.type` of the failure. The
  /// count records as the last step of the span.
  ///
  /// - Parameters:
  ///   - id: The display id of the marketplace.
  ///   - kind: What the pass does.
  ///   - outcome: Gives the outcome of the value of `body`.
  ///   - body: The pass. It runs on the actor of the caller.
  /// - Returns: The value of `body`.
  nonisolated(nonsending) static func tracePass<Output>(
    id: String,
    kind: MarketplacePassKind,
    outcome: (Output) -> MarketplacePassOutcome,
    _ body: nonisolated(nonsending) () async -> Output
  ) async -> Output {
    await InstrumentationSystem.tracer.withSpan(SpanName.pass) { span in
      span.attributes[AttributeKey.marketplaceID] = id
      span.attributes[AttributeKey.passKind] = kind.rawValue
      let output = await body()
      let passOutcome = outcome(output)
      span.attributes[AttributeKey.passOutcome] = passOutcome.rawValue
      if passOutcome == .failed {
        span.setStatus(SpanStatus(code: .error))
      }
      makePassCounter(id: id, kind: kind, outcome: passOutcome).increment()
      return output
    }
  }

  /// Runs one step of a pass in one span through ``TracedCall``.
  ///
  /// The step writes one "enter" log record when it starts. When `body`
  /// throws, the span gets the error status and the `error.type` of the
  /// error, never its description.
  ///
  /// - Parameters:
  ///   - spanName: The name of the span, from ``SpanName``.
  ///   - id: The display id of the marketplace.
  ///   - body: The step. It runs on the actor of the caller.
  /// - Returns: The value of `body`.
  /// - Throws: The error of `body`.
  nonisolated(nonsending) static func traceStep<Output>(
    _ spanName: String,
    id: String,
    _ body: nonisolated(nonsending) () async throws -> Output
  ) async throws -> Output {
    try await TracedCall.run(
      spanName,
      logger: makeLogger(),
      attributes: { $0[AttributeKey.marketplaceID] = id },
      metadata: [LogMetadataKey.marketplaceID: .string(id)]
    ) { _ in
      try await body()
    }
  }

  /// Runs one git call in one span through ``traceStep(_:id:_:)``, and
  /// records its duration on the timer `timerLabel`.
  ///
  /// The timer records as the last step of the span, on the success path
  /// and on the error path, with the ``MarketplaceCallOutcome`` of the call.
  /// Thus the duration and the span measure the same interval, and a failed
  /// or a hung call that ends also records its duration.
  ///
  /// - Parameters:
  ///   - spanName: The name of the span, from ``SpanName``.
  ///   - timerLabel: The label of the timer, from ``MetricName``.
  ///   - id: The display id of the marketplace.
  ///   - body: The git call. It runs on the actor of the caller.
  /// - Returns: The value of `body`.
  /// - Throws: The error of `body`.
  nonisolated(nonsending) static func traceGitCall<Output>(
    _ spanName: String,
    timer timerLabel: String,
    id: String,
    _ body: nonisolated(nonsending) () async throws -> Output
  ) async throws -> Output {
    let start = ContinuousClock.now
    return try await traceStep(spanName, id: id) {
      var outcome = MarketplaceCallOutcome.failed
      defer {
        recordDuration(on: timerLabel, outcomeKey: DimensionKey.gitOutcome, id: id, outcome: outcome, since: start)
      }
      let output = try await body()
      outcome = .succeeded
      return output
    }
  }

  /// Runs one install of a snapshot into the cache, and records its
  /// duration on the install timer.
  ///
  /// The timer records on the success path and on the error path, with the
  /// ``MarketplaceCallOutcome`` of the install. The install is synchronous
  /// file work, thus it cannot go through the asynchronous
  /// ``traceGitCall(_:timer:id:_:)``. Swift has no `reasync`, thus this
  /// helper is the synchronous form of the same timer step, and both record
  /// through one private recorder.
  ///
  /// - Parameters:
  ///   - id: The display id of the marketplace.
  ///   - body: The install.
  /// - Returns: The value of `body`.
  /// - Throws: The error of `body`.
  static func timeInstall<Output>(id: String, _ body: () throws -> Output) rethrows -> Output {
    let start = ContinuousClock.now
    var outcome = MarketplaceCallOutcome.failed
    defer {
      recordDuration(
        on: MetricName.installDuration, outcomeKey: DimensionKey.installOutcome, id: id, outcome: outcome,
        since: start)
    }
    let output = try body()
    outcome = .succeeded
    return output
  }

  /// Adds one count to a counter of the cache of one marketplace.
  ///
  /// The counter is made at call time, so that it uses the metrics factory
  /// that is in effect when the event occurs. Its only dimension is the
  /// display id, thus no path of the cache goes into it.
  ///
  /// - Parameters:
  ///   - counterLabel: The label of the counter, from ``MetricName``: the
  ///     writer-lock conflict counter or the removed-snapshot counter.
  ///   - id: The display id of the marketplace.
  static func count(_ counterLabel: String, id: String) {
    Counter(label: counterLabel, dimensions: [(DimensionKey.marketplaceID, id)]).increment()
  }

  /// Makes the counter of the passes that have one display id, one kind and
  /// one outcome.
  ///
  /// The counter is made at call time, so that it uses the metrics factory
  /// that is in effect when the pass ends.
  ///
  /// - Parameters:
  ///   - id: The display id of the marketplace.
  ///   - kind: What the passes did.
  ///   - outcome: How the passes ended.
  /// - Returns: The counter.
  private static func makePassCounter(
    id: String, kind: MarketplacePassKind, outcome: MarketplacePassOutcome
  ) -> Counter {
    Counter(
      label: MetricName.passes,
      dimensions: [
        (DimensionKey.marketplaceID, id),
        (DimensionKey.passKind, kind.rawValue),
        (DimensionKey.passOutcome, outcome.rawValue),
      ])
  }

  /// Records one duration on a timer of the target: a git timer or the
  /// install timer.
  ///
  /// The timer is made at call time, so that it uses the metrics factory that
  /// is in effect when the call ends.
  ///
  /// - Parameters:
  ///   - timerLabel: The label of the timer.
  ///   - outcomeKey: The dimension key of the outcome of the timer, from
  ///     ``DimensionKey``.
  ///   - id: The display id of the marketplace.
  ///   - outcome: How the call ended.
  ///   - start: The instant that the call started.
  private static func recordDuration(
    on timerLabel: String, outcomeKey: String, id: String, outcome: MarketplaceCallOutcome,
    since start: ContinuousClock.Instant
  ) {
    Metrics.Timer(
      label: timerLabel,
      dimensions: [(DimensionKey.marketplaceID, id), (outcomeKey, outcome.rawValue)]
    )
    .record(duration: ContinuousClock.now - start)
  }
}

/// What one pass over a marketplace does. It is the value of the
/// ``MarketplaceTelemetry/AttributeKey/passKind`` attribute and dimension.
enum MarketplacePassKind: String, Sendable, CaseIterable {
  /// The pass reads the remote head and reports it. It fetches nothing.
  case check

  /// The pass reads the remote head, and installs it when it differs from
  /// the snapshot on the disk.
  case update
}

/// How one pass over a marketplace ended. It is the value of the
/// ``MarketplaceTelemetry/AttributeKey/passOutcome`` attribute and dimension.
///
/// ``MarketplaceTelemetry/passOutcome(of:)`` gives it from the event of the
/// pass. No other value is possible, thus the dimension has a fixed
/// cardinality.
enum MarketplacePassOutcome: String, Sendable, CaseIterable {
  /// The marketplace needs no change: the snapshot is the remote head, or
  /// the marketplace is a local folder or a seed entry.
  case upToDate = "up_to_date"

  /// The pass installed a new snapshot, and `current` now names it.
  case updated

  /// The remote holds a commit that the snapshot does not, and the pass did
  /// not install it: the pass was a check or a dry run, or the policy keeps
  /// the new snapshot for the next launch.
  case updateAvailable = "update_available"

  /// The pass could not bring the marketplace to its remote head. The last
  /// good snapshot stays in place.
  case failed
}

/// How one timed call ended: a fetch, a read of the remote head, or an
/// install of a snapshot. It is the value of the
/// ``MarketplaceTelemetry/DimensionKey/gitOutcome`` dimension and of the
/// ``MarketplaceTelemetry/DimensionKey/installOutcome`` dimension.
enum MarketplaceCallOutcome: String, Sendable, CaseIterable {
  /// The call returned: the git call gave a commit, or the install put the
  /// snapshot in place.
  case succeeded

  /// The call threw an error: the transport failed, the fetch timed out, the
  /// call was cancelled, or a file step of the install failed.
  case failed
}
