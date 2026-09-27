import Metal
import Testing

/// The check that each real-model test does first.
///
/// The check fails the test, and does not skip it. A skip gives a green run
/// that measured nothing, and this suite exists to prevent that result.
enum ModelAvailability {
    /// Stops the test with a clear failure when this machine has no Metal
    /// device. MLX runs each model on a Metal device.
    ///
    /// - Throws: The expectation failure of Swift Testing.
    static func requireMetalDevice() throws {
        try #require(
            MTLCreateSystemDefaultDevice() != nil,
            "This machine has no Metal device, thus MLX cannot load the models of this suite.")
    }
}
