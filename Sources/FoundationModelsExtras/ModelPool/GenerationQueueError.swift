import Foundation

/// A refusal of a job that ``GenerationQueue`` could never start.
public enum GenerationQueueError: Error, Equatable, LocalizedError {
    /// A task inside an open model call on the queue of `model` submitted a
    /// job to that same queue. The job waits behind the call that waits for
    /// it, so the queue refuses it at once.
    case waitInsideOpenSubmission(model: ModelRef)

    /// A localized message that describes the error.
    public var errorDescription: String? {
        switch self {
        case .waitInsideOpenSubmission(let model):
            return """
                A tool body inside a submission to \(model.stringValue) waited for another submission to \
                \(model.stringValue). That submission can run only after the submission of the tool body \
                ends, so the wait could never end. Start the work from a background tool, and let its \
                result come back as mail, or wait for work on a different model.
                """
        }
    }
}
