import Logging

/// One place of the telemetry that a capture recorded, as text that a reader
/// can find in the telemetry backend.
///
/// ``TelemetryCapture/Context/leaks(forbidding:)`` compares the
/// ``description`` of each place with each forbidden string. Thus a forbidden
/// string in a name, a key or a value of the place is a leak.
public enum TelemetryPlace: Sendable, Equatable, CustomStringConvertible {
    /// The name of a span, as `span <span>`.
    case spanName(String)

    /// One attribute of a span, as `<span>.<key> = <value>`.
    case spanAttribute(span: String, key: String, value: String)

    /// The message of a log record, as `log <level>: <message>`.
    case logMessage(level: Logger.Level, message: String)

    /// One metadata value of a log record, as `log metadata <key> = <value>`.
    case logMetadata(key: String, value: String)

    /// The name of a metric, as `metric <metric>`.
    case metricName(String)

    /// One dimension of a metric, as `metric <metric> <key> = <value>`.
    case metricDimension(metric: String, key: String, value: String)

    /// The place as text, in the form that the doc comment of its case gives.
    public var description: String {
        switch self {
        case let .spanName(span):
            "span \(span)"
        case let .spanAttribute(span, key, value):
            "\(span).\(key) = \(value)"
        case let .logMessage(level, message):
            "log \(level): \(message)"
        case let .logMetadata(key, value):
            "log metadata \(key) = \(value)"
        case let .metricName(metric):
            "metric \(metric)"
        case let .metricDimension(metric, key, value):
            "metric \(metric) \(key) = \(value)"
        }
    }
}

/// A place that contains a forbidden string.
public struct TelemetryLeak: Sendable, Equatable, CustomStringConvertible {
    /// The place that contains the forbidden string.
    public let place: TelemetryPlace

    /// The forbidden string that the place contains.
    public let forbidden: String

    /// Makes a leak.
    ///
    /// - Parameters:
    ///   - place: The place that contains the forbidden string.
    ///   - forbidden: The forbidden string that the place contains.
    public init(place: TelemetryPlace, forbidden: String) {
        self.place = place
        self.forbidden = forbidden
    }

    /// The text of the issue that ``TelemetryCapture`` records for the leak.
    public var description: String {
        "telemetry carries the forbidden text \"\(forbidden)\" at: \(place)"
    }
}

/// One dimension of a metric: a name and a value.
public struct MetricDimension: Sendable, Equatable {
    /// The name of the dimension.
    public let key: String

    /// The value of the dimension.
    public let value: String

    /// Makes a dimension.
    ///
    /// - Parameters:
    ///   - key: The name of the dimension.
    ///   - value: The value of the dimension.
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// One metric that a capture made.
public struct MetricRecord: Sendable, Equatable {
    /// The kinds of metric that the metrics factory makes.
    public enum Kind: String, Sendable, Equatable {
        /// A counter. A floating-point counter is a counter too.
        case counter

        /// A meter.
        case meter

        /// A recorder. A gauge is a recorder too.
        case recorder

        /// A timer.
        case timer
    }

    /// The kind of the metric.
    public let kind: Kind

    /// The name of the metric.
    public let label: String

    /// The dimensions of the metric, in the order of the call.
    public let dimensions: [MetricDimension]

    /// Makes a metric record.
    ///
    /// - Parameters:
    ///   - kind: The kind of the metric.
    ///   - label: The name of the metric.
    ///   - dimensions: The dimensions of the metric, in the order of the call.
    public init(kind: Kind, label: String, dimensions: [MetricDimension]) {
        self.kind = kind
        self.label = label
        self.dimensions = dimensions
    }

    /// Makes a metric record from the dimension tuples of swift-metrics.
    ///
    /// - Parameters:
    ///   - kind: The kind of the metric.
    ///   - label: The name of the metric.
    ///   - dimensions: The `(name, value)` tuples of the metric.
    init(kind: Kind, label: String, dimensions: [(String, String)]) {
        self.init(kind: kind, label: label, dimensions: dimensions.map { MetricDimension(key: $0.0, value: $0.1) })
    }

    /// The places of the metric: its name, then each dimension.
    var places: [TelemetryPlace] {
        [.metricName(label)]
            + dimensions.map { .metricDimension(metric: label, key: $0.key, value: $0.value) }
    }
}
