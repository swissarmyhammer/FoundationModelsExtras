import Testing

/// The one parent suite of each real-model suite of this package.
///
/// Swift Testing runs two suites at the same time, and `.serialized` on one
/// suite does not stop a different suite. Each real-model suite is thus a nested
/// suite of this type, in an extension, and `.serialized` here reaches each
/// test of each nested suite. Thus one real-model test runs at a time in the
/// process, and for these reasons:
///
/// - A memory check reads the MLX counters of the process. A model that a
///   different test loads at the same time makes the check wrong.
/// - `MLXLanguageModel` keeps its weights in one model cache for each process.
///   A pool of a different test that evicts the same model removes the weights
///   under the hold of this test.
/// - A time measurement of a queue test must not include the GPU work of a
///   different test.
@Suite("Real models", .serialized)
enum RealModelSuites {
    /// The longest time that one real-model test may take. Each nested suite
    /// sets it with `.timeLimit`, thus a hang fails its test and does not block
    /// CI. A first run on a new machine downloads the models, thus the limit is
    /// much longer than a normal run.
    static let testTimeLimitMinutes = 10
}
