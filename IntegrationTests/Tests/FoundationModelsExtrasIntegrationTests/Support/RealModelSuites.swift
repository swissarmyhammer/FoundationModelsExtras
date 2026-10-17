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
///
/// A suite whose tests only use a model declares the ``SharedLoadsTrait``:
/// the trait loads each model of the suite one time, and evicts it after the
/// last test of the suite. A suite whose tests examine a load of their own has
/// no trait, and each of its tests loads and evicts its model. One suite runs
/// at a time, thus a test never loads a model that a shared hold of a
/// different suite keeps.
///
/// No suite sets a time limit. Each wait of a test ends on the event that it
/// expects, or on an event that shows the fault: the model call returns or
/// throws, a stream ends, a run settles, a task ends. A hang of MLX or a
/// stalled download gives no event. Then the run stops making output, and the
/// person or the session that watches the run cancels it. The last lines of
/// the log name the test and the call that stopped.
@Suite("Real models", .serialized)
enum RealModelSuites {}
