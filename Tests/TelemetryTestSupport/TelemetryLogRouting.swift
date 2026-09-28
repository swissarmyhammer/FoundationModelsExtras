import InMemoryLogging
import Logging

/// Sends each log record of the process to the capture of its task.
///
/// swift-log has no task-local logger, thus the capture bootstraps the logging
/// system one time for each process with ``RoutingLogHandler``. The handler
/// reads the capture of the current task from ``currentContext`` at each
/// record.
enum TelemetryLogRouting {
    /// The capture of the current task, or `nil` outside a capture.
    static let currentContext = TaskLocal<TelemetryCapture.Context?>(wrappedValue: nil)

    /// Bootstraps the logging system with ``RoutingLogHandler``.
    ///
    /// Swift runs the initializer of a static constant one time, on the first
    /// read. Thus the bootstrap happens one time for each process, however
    /// many captures read this constant.
    static let bootstrapOnce: Void = LoggingSystem.bootstrap { _ in RoutingLogHandler() }
}

/// A log handler that sends each record to the capture of the current task.
///
/// A record outside a capture goes nowhere. The handler lets each level pass,
/// so that the capture sees the records of each level.
struct RoutingLogHandler: LogHandler {
    /// The metadata of the logger that holds this handler.
    var metadata: Logger.Metadata = [:]

    /// The metadata provider of the logger that holds this handler.
    var metadataProvider: Logger.MetadataProvider?

    /// The lowest level that the logger sends to this handler.
    var logLevel: Logger.Level = .trace

    /// Reads or writes one metadata value of the logger.
    ///
    /// - Parameter key: The metadata key.
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    /// Sends `event` to the in-memory handler of the capture of the current
    /// task. That handler merges the metadata of this handler, the provided
    /// metadata and the metadata of the call into the record.
    ///
    /// - Parameter event: The log record.
    func log(event: LogEvent) {
        guard let context = TelemetryLogRouting.currentContext.get() else {
            return
        }
        var handler = context.logHandler
        handler.metadata = metadata
        handler.metadataProvider = metadataProvider
        handler.log(event: event)
    }
}
