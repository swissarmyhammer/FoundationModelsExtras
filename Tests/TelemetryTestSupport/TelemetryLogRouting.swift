import Logging
import Synchronization

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
    /// many captures read this constant. The factory gives the label of each
    /// new logger to its handler, thus each record keeps that label.
    static let bootstrapOnce: Void = LoggingSystem.bootstrap { label in
        RoutingLogHandler(label: label, destination: .currentCapture)
    }
}

/// A log handler that writes each record, with the label of its logger, to
/// the log record store of a capture.
///
/// A record with no capture goes nowhere. The handler lets each level pass,
/// so that the capture sees the records of each level.
struct RoutingLogHandler: LogHandler {
    /// The capture that gets the records of a handler.
    enum Destination: Sendable {
        /// The capture of the task that writes the record, or no capture
        /// outside a capture.
        case currentCapture

        /// One capture, through its log record store.
        case store(LogRecordStore)
    }

    /// The label of the logger that holds this handler.
    let label: String

    /// The capture that gets the records of this handler.
    let destination: Destination

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

    /// Appends `event` to the store of the destination, with the label of this
    /// handler and the merged metadata.
    ///
    /// - Parameter event: The log record.
    func log(event: LogEvent) {
        guard let store = destinationStore else {
            return
        }
        store.append(record: TelemetryCapture.LogRecord(
            level: event.level,
            message: event.message,
            error: event.error,
            metadata: mergedMetadata(of: event),
            label: label
        ))
    }

    /// The log record store of the destination, or `nil` when the current
    /// task has no capture.
    private var destinationStore: LogRecordStore? {
        switch destination {
        case .currentCapture:
            TelemetryLogRouting.currentContext.get()?.logRecordStore
        case .store(let store):
            store
        }
    }

    /// The metadata of one record, as swift-log's `InMemoryLogHandler` merges
    /// it: the metadata of the handler, then the provided metadata, then the
    /// metadata of the call. A later value replaces an earlier value with the
    /// same key.
    ///
    /// - Parameter event: The log record.
    /// - Returns: The merged metadata.
    private func mergedMetadata(of event: LogEvent) -> Logger.Metadata {
        let provided = metadataProvider?.get() ?? [:]
        return metadata
            .merging(provided) { _, later in later }
            .merging(event.metadata ?? [:]) { _, later in later }
    }
}

/// The log records of one capture, in the order of the calls.
///
/// The log handlers of the capture append to the store from each thread, thus
/// a mutex holds the records.
final class LogRecordStore: Sendable {
    /// The records, in the order of the calls.
    private let storage = Mutex<[TelemetryCapture.LogRecord]>([])

    /// The records, in the order of the calls.
    var records: [TelemetryCapture.LogRecord] {
        storage.withLock { $0 }
    }

    /// Appends one record.
    ///
    /// - Parameter record: The record to append.
    func append(record: TelemetryCapture.LogRecord) {
        storage.withLock { $0.append(record) }
    }
}
