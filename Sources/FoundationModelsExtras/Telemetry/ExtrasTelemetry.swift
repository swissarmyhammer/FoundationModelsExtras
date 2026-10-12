import Logging
import Metrics

/// The telemetry vocabulary of the core target: the span names, the attribute
/// keys, the metric names, the dimension keys, the log metadata keys and the
/// carrier keys of the W3C trace context, the queue names and the bounded
/// outcome values, and the logger and the tool-call metrics that use them.
///
/// Each package keeps all of its telemetry names in one vocabulary file. No
/// other source file of the core target writes a telemetry name as a string
/// literal.
///
/// Each span name, logger label and metric name starts with the module name. A
/// metadata key of a log record has the dotted form of an attribute key, for
/// example `trace.id`. The core target uses the swift-log
/// and swift-metrics APIs only, and it bootstraps no backend. The executables
/// of the family bootstrap the backend. Until one does, each metric does
/// nothing, and each logger writes through the default handler of swift-log.
///
/// A metric dimension carries names and bounded values only: the tool name,
/// the queue name, the model ref of a queue, a pool metric or a model metric
/// that belongs to one model, the role of a model, the bounded telemetry value
/// of an outcome, the cache result of a pool acquire, and the reason of a
/// skipped eviction. It never carries tool arguments, tool output, the content
/// of a queue task, a file path, a cache folder, a URL or the description of a
/// container or of an error, because a dimension leaves the process through
/// the metrics backend of the host.
enum ExtrasTelemetry {
    /// The label of each logger of the core target.
    static let logLabel = "FoundationModelsExtras"

    /// The span names of the core target.
    enum SpanName {
        /// The span of one mounted tool call.
        static let tool = "FoundationModelsExtras.tool"

        /// The span of the body of one background run of the run plane. It
        /// starts when the body starts, and it ends when the body returns.
        static let run = "FoundationModelsExtras.run"

        /// The span of one load of a model by a model pool: the call to the
        /// loader, from its start to its return.
        static let modelLoad = "FoundationModelsExtras.model.load"

        /// The span of the install of the MLX metal library in one load.
        static let modelLoadMetalInstall = "FoundationModelsExtras.model.load.metal_install"

        /// The span of the download of the files of a model in one load. The
        /// download returns at once when the cache holds the files.
        static let modelLoadDownload = "FoundationModelsExtras.model.load.download"

        /// The span of the load of the weights of a model in one load. The
        /// MLX model factory downloads the files first, thus the download
        /// span is inside this span.
        static let modelLoadWeights = "FoundationModelsExtras.model.load.weights"

        /// The span of the `preload()` of an LLM in one load. The preload
        /// calls the load closure of the model, thus the weights span of an
        /// LLM is inside this span.
        static let modelLoadPreload = "FoundationModelsExtras.model.load.preload"
    }

    /// The attribute keys of the spans of the core target.
    enum AttributeKey {
        /// The model-facing name of the tool.
        static let toolName = "tool.name"

        /// The session that the call runs in.
        static let sessionID = "session.id"

        /// The ``ToolCallSpan/ToolRunKind`` of the call.
        static let runKind = "tool.run_kind"

        /// The ``RunKind`` of a background run of the run plane.
        static let backgroundRunKind = "run.kind"

        /// The completion token of a background run. It is a span attribute
        /// and log metadata only, never a metric dimension, because each run
        /// has a new token and the cardinality has no limit.
        static let completionToken = "run.completion_token"

        /// The bounded telemetry value of the ``OperationOutcome`` of the
        /// call, from ``ExtrasTelemetry/telemetryOutcome(of:)``.
        static let outcome = "tool.outcome"

        /// Whether the run of a background call settled inside its settle
        /// period: `true` when the call answers from the run, `false` when
        /// the call answers with the pending envelope.
        static let settledInline = "tool.settled_inline"

        /// The type of the error that ended a traced call: the type name, then
        /// the enum case name when reflection shows one. Never the description
        /// of the error, because a description can hold content.
        static let errorType = "error.type"

        /// The `ModelRef.stringValue` of the model of a load span. It has the
        /// same key as the metric dimension.
        static let modelRef = DimensionKey.modelRef

        /// The revision of the model of a load span. A model ref that names
        /// no revision has the default revision of the Hugging Face hub.
        static let modelRevision = "model.revision"

        /// The role of the model of a load span, from
        /// ``ExtrasTelemetry/telemetryRole(of:)``. It has the same key as the
        /// metric dimension.
        static let modelRole = DimensionKey.modelRole

        /// The bytes that the download of a model completed, from the last
        /// progress of the download. It is 0 when the cache held the files.
        static let downloadBytes = "download.bytes"
    }

    /// The metric names of the core target.
    enum MetricName {
        /// The counter that counts each tool call.
        static let toolCalls = "FoundationModelsExtras.tool.calls"

        /// The timer that records the duration of each tool call.
        static let toolDuration = "FoundationModelsExtras.tool.duration"

        /// The meter of the depth of a queue: the count of its tasks that are
        /// not finished, waiting and running together.
        static let queueDepth = "FoundationModelsExtras.queue.depth"

        /// The timer that records the time of each queue task from its
        /// enqueue to its start.
        static let queueWait = "FoundationModelsExtras.queue.wait"

        /// The timer that records the time of each queue task from its start
        /// to its end.
        static let queueRun = "FoundationModelsExtras.queue.run"

        /// The counter that counts each queue task that completes.
        static let queueTasks = "FoundationModelsExtras.queue.tasks"

        /// The counter that counts each acquire of a model pool, with the
        /// ``PoolCacheResult`` of the acquire.
        static let poolAcquires = "FoundationModelsExtras.pool.acquires"

        /// The counter that counts each eviction of a model pool when the
        /// evict call of the loader returns, and each eviction job that a
        /// new hold stopped, with a ``PoolEvictionSkipReason``.
        static let poolEvictions = "FoundationModelsExtras.pool.evictions"

        /// The timer that records the time of each evicted model from its
        /// last release to the start of its eviction.
        static let poolIdleToEvict = "FoundationModelsExtras.pool.idle_to_evict"

        /// The meter of the bytes of the resident models of a model pool. A
        /// model whose evict call runs is resident, as in the footprint.
        static let poolResidentBytes = "FoundationModelsExtras.pool.resident_bytes"

        /// The meter of the bytes of the load that a model pool runs now.
        static let poolLoadingBytes = "FoundationModelsExtras.pool.loading_bytes"

        /// The meter of the bytes of the models whose evict call runs now.
        static let poolEvictingBytes = "FoundationModelsExtras.pool.evicting_bytes"

        /// The meter of the number of resident models of a model pool.
        static let poolResidentModels = "FoundationModelsExtras.pool.resident_models"

        /// The counter that counts each caller that waits for a load of a
        /// pooled model that another caller started.
        static let poolLoadJoins = "FoundationModelsExtras.pool.load_joins"

        /// The timer that records the duration of each load of a model by a
        /// model pool, with the ``ModelOperationOutcome`` of the load.
        static let modelLoadDuration = "FoundationModelsExtras.model.load.duration"

        /// The recorder of the bytes that the footprint measure of a loaded
        /// model gives.
        static let modelFootprintBytes = "FoundationModelsExtras.model.footprint.bytes"
    }

    /// The dimension keys of the queue metrics, the pool metrics and the
    /// model metrics of the core target.
    enum DimensionKey {
        /// The ``QueueName`` of the queue.
        static let queueName = "queue.name"

        /// The `ModelRef.stringValue` of the model that the queue, the pool
        /// metric or the model metric belongs to. Only a queue of one model, a
        /// pool metric of one model and a model metric have this dimension.
        static let modelRef = "model.ref"

        /// The ``QueueOutcome`` of a completed queue task.
        static let queueOutcome = "queue.outcome"

        /// The ``PoolCacheResult`` of an acquire of a model pool.
        static let cacheResult = "cache.result"

        /// The ``PoolEvictionSkipReason`` of an eviction job that evicted
        /// nothing. An eviction that occurred has no reason.
        static let evictionReason = "reason"

        /// The role of the model of a model metric, from
        /// ``ExtrasTelemetry/telemetryRole(of:)``.
        static let modelRole = "model.role"

        /// The ``ModelOperationOutcome`` of a load of a model.
        static let modelOutcome = "model.outcome"
    }

    /// The metadata keys of the log records of the core target.
    enum LogMetadataKey {
        /// The W3C trace id of the span of a call.
        static let traceID = "trace.id"

        /// The W3C span id of the span of a call.
        static let spanID = "span.id"

        /// The model-facing name of the tool. It has the same key as the span
        /// attribute.
        static let toolName = AttributeKey.toolName

        /// The session that the call runs in. It has the same key as the span
        /// attribute.
        static let sessionID = AttributeKey.sessionID

        /// The ``RunKind`` of a background run. It has the same key as the
        /// span attribute.
        static let backgroundRunKind = AttributeKey.backgroundRunKind

        /// The completion token of a background run. It has the same key as
        /// the span attribute.
        static let completionToken = AttributeKey.completionToken

        /// The type of the error of a log record, from
        /// ``ExtrasTelemetry/errorType(of:)``. It has the same key as the
        /// span attribute.
        static let errorType = AttributeKey.errorType

        /// The `ModelRef.stringValue` of the model of a log record. It has the
        /// same key as the metric dimension.
        static let modelRef = DimensionKey.modelRef

        /// The role of the model of a log record, from
        /// ``ExtrasTelemetry/telemetryRole(of:)``. It has the same key as the
        /// metric dimension.
        static let modelRole = DimensionKey.modelRole
    }

    /// The messages of the log records of the model pool.
    enum PoolLogMessage {
        /// The message of the record that a failed footprint measure writes.
        /// The loader evicted the model, and the acquire throws the error.
        static let measureFailed = "the footprint measure of a loaded model failed; the loader evicted the model"
    }

    /// The carrier keys of the W3C trace context: the fields that carry the
    /// span context of a call across a process boundary, for example in an
    /// HTTP header or in the `_meta` of an ACP or MCP request.
    enum TraceContextField {
        /// The key of the W3C `traceparent` value: the version, the trace id,
        /// the span id and the trace flags.
        static let traceparent = "traceparent"

        /// The key of the W3C `tracestate` value: the vendor data of the
        /// trace, as a list of `key=value` members.
        static let tracestate = "tracestate"
    }

    /// The message of the "enter" log record that ``TracedCall`` writes when a
    /// call starts.
    enum EnterRecord {
        /// The text before the span name in the message of the record.
        static let messagePrefix = "enter "

        /// Gives the message of the record of one call.
        ///
        /// - Parameter spanName: The name of the span of the call.
        /// - Returns: `enter <spanName>`.
        static func message(forSpanNamed spanName: String) -> String {
            messagePrefix + spanName
        }
    }

    /// The text between the type name and the case name in an
    /// ``AttributeKey/errorType`` value.
    private static let errorTypeCaseSeparator = "."

    /// Gives the ``AttributeKey/errorType`` value of `error`: the full type
    /// name, then the enum case name when reflection shows one.
    ///
    /// Reflection shows the case name of an enum case that has a payload. It
    /// shows no case name for a case with no payload, thus the value of such a
    /// case is the type name only. The value never holds the description or
    /// the payload of the error, because they can hold content.
    ///
    /// The value of a `CustomReflectable` error is the type name only.
    /// `Mirror(reflecting:)` uses the `customMirror` of such an error, and a
    /// custom mirror can put any text, also a payload, in the label of a
    /// child.
    ///
    /// - Parameter error: The error that ended a traced call.
    /// - Returns: The type name, with its module, for example
    ///   `MyModule.LoadError`, then the case name, for example
    ///   `MyModule.LoadError.missing` for `LoadError.missing(path)`.
    static func errorType(of error: any Error) -> String {
        let typeName = String(reflecting: type(of: error))
        guard !(error is any CustomReflectable) else {
            return typeName
        }
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum, let caseName = mirror.children.first?.label else {
            return typeName
        }
        return typeName + errorTypeCaseSeparator + caseName
    }

    /// Makes a logger with the label of the core target.
    ///
    /// Make the logger at call time, not in a stored value. A logger keeps the
    /// handler of the time that it was made.
    ///
    /// - Returns: A logger that writes through the logging backend of the
    ///   host.
    static func makeLogger() -> Logger {
        Logger(label: logLabel)
    }

    /// Makes the counter of the tool calls that have one tool name and one
    /// outcome.
    ///
    /// - Parameters:
    ///   - toolName: The model-facing name of the tool.
    ///   - outcome: How the call ended.
    /// - Returns: The counter, with the tool name and the outcome as its
    ///   only dimensions.
    static func makeToolCallCounter(toolName: String, outcome: OperationOutcome) -> Counter {
        Counter(label: MetricName.toolCalls, dimensions: toolCallDimensions(toolName: toolName, outcome: outcome))
    }

    /// Makes the timer of the tool calls that have one tool name and one
    /// outcome.
    ///
    /// - Parameters:
    ///   - toolName: The model-facing name of the tool.
    ///   - outcome: How the call ended.
    /// - Returns: The timer, with the tool name and the outcome as its only
    ///   dimensions.
    static func makeToolDurationTimer(toolName: String, outcome: OperationOutcome) -> Metrics.Timer {
        Metrics.Timer(
            label: MetricName.toolDuration,
            dimensions: toolCallDimensions(toolName: toolName, outcome: outcome)
        )
    }

    /// Records one tool call: one count on the counter and one duration on
    /// the timer of its tool name and outcome.
    ///
    /// The metrics are made at call time, so that they use the metrics
    /// factory that is in effect when the call ends.
    ///
    /// - Parameters:
    ///   - toolName: The model-facing name of the tool.
    ///   - outcome: How the call ended.
    ///   - duration: The duration of the call.
    static func recordToolCall(toolName: String, outcome: OperationOutcome, duration: Duration) {
        makeToolCallCounter(toolName: toolName, outcome: outcome).increment()
        makeToolDurationTimer(toolName: toolName, outcome: outcome).record(duration: duration)
    }

    /// Gives the dimensions of a tool-call metric.
    ///
    /// - Parameters:
    ///   - toolName: The model-facing name of the tool.
    ///   - outcome: How the call ended.
    /// - Returns: The tool name and the telemetry value of the outcome, with
    ///   the attribute keys of the tool span as the dimension names.
    private static func toolCallDimensions(toolName: String, outcome: OperationOutcome) -> [(String, String)] {
        [
            (AttributeKey.toolName, toolName),
            (AttributeKey.outcome, telemetryOutcome(of: outcome).rawValue),
        ]
    }

    /// Gives the bounded telemetry value of a model role: the value of the
    /// ``AttributeKey/modelRole`` attribute and of the
    /// ``DimensionKey/modelRole`` dimension.
    ///
    /// - Parameter role: The role of a model.
    /// - Returns: `llm` or `embedding`.
    static func telemetryRole(of role: ModelRole) -> String {
        switch role {
        case .llm: "llm"
        case .embedding: "embedding"
        }
    }

    /// Gives the bounded telemetry value of a tool outcome.
    ///
    /// Each telemetry use of a tool outcome, a metric dimension or a span
    /// attribute, uses this value and never `OperationOutcome.rawValue`. The
    /// `rawValue` of ``OperationOutcome/other(_:)`` is the text of the tool,
    /// thus it has no cardinality limit, and it can hold content. The
    /// `rawValue` stays the wire format.
    ///
    /// The value keeps each case of ``OperationOutcome`` separate. It never
    /// gives `failed` for ``OperationOutcome/lost``, because "we do not know
    /// if this ran" is not the claim "this ran and failed". It keeps
    /// ``OperationOutcome/stopped`` and ``OperationOutcome/cancelled``
    /// separate, because a stop is authoritative and a cancel is only a
    /// request.
    ///
    /// - Parameter outcome: How a tool call or a run ended.
    /// - Returns: One fixed value for each case. Each
    ///   ``OperationOutcome/other(_:)`` gives ``QueueOutcome/other``.
    static func telemetryOutcome(of outcome: OperationOutcome) -> QueueOutcome {
        switch outcome {
        case .succeeded: .succeeded
        case .failed: .failed
        case .timedOut: .timedOut
        case .stopped: .stopped
        case .cancelled: .cancelled
        case .lost: .lost
        case .other: .other
        }
    }
}

/// The name of each queue of the package that records queue metrics. It is
/// the value of the ``ExtrasTelemetry/DimensionKey/queueName`` dimension.
///
/// No other queue name is possible, thus the dimension has a fixed
/// cardinality.
enum QueueName: String, Sendable, CaseIterable {
    /// The work queue of one pooled model.
    case model

    /// The admission queue of the model pool.
    case admission

    /// The generation queue of a session.
    case generation

    /// The open runs of the run plane.
    case runPlane = "run_plane"

    /// The queue of the elicitation requests.
    case elicitation

    /// The delivery chain of the tool events.
    case toolEvents = "tool_events"

    /// The mailbox that posts messages to a session.
    case mailbox
}

/// The bounded telemetry value of how a queue task or a tool call ended. It is
/// the value of the ``ExtrasTelemetry/DimensionKey/queueOutcome`` dimension,
/// and ``ExtrasTelemetry/telemetryOutcome(of:)`` gives it for an
/// ``OperationOutcome``.
enum QueueOutcome: String, Sendable, CaseIterable {
    /// The work finished and reported success.
    case succeeded

    /// The work finished and reported failure.
    case failed

    /// The own hard timeout of the work ended it.
    case timedOut = "timed_out"

    /// The work was terminated authoritatively.
    case stopped

    /// Cancellation was requested, or the task was cancelled before it
    /// started.
    case cancelled

    /// The outcome is unknowable.
    case lost

    /// An outcome that this package does not know. The value never holds the
    /// text of that outcome.
    case other
}

/// How a model pool gave one hold. It is the value of the
/// ``ExtrasTelemetry/DimensionKey/cacheResult`` dimension.
enum PoolCacheResult: String, Sendable, CaseIterable {
    /// The model was resident when the acquire started, so the acquire did
    /// not wait for the admission queue.
    case hit

    /// The model was not resident when the acquire started, but it was
    /// resident when the acquire ran in the admission queue.
    case lateHit = "late_hit"

    /// The acquire loaded the model.
    case load
}

/// How a load of a model ended. It is the value of the
/// ``ExtrasTelemetry/DimensionKey/modelOutcome`` dimension.
enum ModelOperationOutcome: String, Sendable, CaseIterable {
    /// The loader returned a model.
    case succeeded

    /// The loader threw an error.
    case failed
}

/// Why an eviction job of a model pool evicted nothing. It is the value of
/// the ``ExtrasTelemetry/DimensionKey/evictionReason`` dimension.
enum PoolEvictionSkipReason: String, Sendable, CaseIterable {
    /// A new hold of the model came before the eviction job ran.
    case rehold
}
