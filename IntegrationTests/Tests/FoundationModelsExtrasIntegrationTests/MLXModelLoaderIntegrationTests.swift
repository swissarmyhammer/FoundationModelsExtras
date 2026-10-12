@testable import FoundationModelsExtras
import HuggingFace
import InMemoryTracing
import TelemetryTestSupport
import Testing
import Tracing

/// The tokenizer loads that one load of one real model causes.
private let tokenizerLoadsOfOneModelLoad = 1

/// The number of spans that one load opens with one name.
private let oneSpanOfEachName = 1

/// One phase span of a real load, and the span that is its parent.
private struct PhaseParent {
    /// The name of the phase span.
    let phase: String

    /// The name of the span that is the parent of the phase span.
    let parent: String
}

/// The phase spans that one real load of a model of `role` opens, each with
/// the name of its parent span. The MLX model factory downloads the files
/// before it loads the weights, thus the download span is a child of the
/// weights span. The `preload()` of an LLM calls the load closure of the
/// model, thus the weights span of an LLM is a child of the preload span.
///
/// - Parameter role: The role of the loaded model.
/// - Returns: The phase spans of the load, each with its parent.
private func phaseParents(of role: ModelRole) -> [PhaseParent] {
    let load = ExtrasTelemetry.SpanName.modelLoad
    let weights = ExtrasTelemetry.SpanName.modelLoadWeights
    let installAndDownload = [
        PhaseParent(phase: ExtrasTelemetry.SpanName.modelLoadMetalInstall, parent: load),
        PhaseParent(phase: ExtrasTelemetry.SpanName.modelLoadDownload, parent: weights),
    ]
    switch role {
    case .llm:
        let preload = ExtrasTelemetry.SpanName.modelLoadPreload
        return installAndDownload + [
            PhaseParent(phase: preload, parent: load),
            PhaseParent(phase: weights, parent: preload),
        ]
    case .embedding:
        return installAndDownload + [PhaseParent(phase: weights, parent: load)]
    }
}

/// Gives the one span of `spans` that has the name `name`.
///
/// - Parameters:
///   - name: The name of the span.
///   - spans: The spans of one capture.
/// - Returns: The span with that name.
/// - Throws: When `spans` holds no span with that name.
private func onlySpan(named name: String, in spans: [FinishedInMemorySpan]) throws -> FinishedInMemorySpan {
    let named = spans.filter { $0.operationName == name }
    #expect(named.count == oneSpanOfEachName, "spans named \(name)")
    return try #require(named.first)
}

extension RealModelSuites {
    /// `MLXModelLoader(tokenizerLoader:)` with real models: each load, of an LLM
    /// and of an embedding model, loads the tokenizer with the tokenizer loader
    /// of the init. Each load also opens one load span with its phase spans.
    @Suite("MLX model loader with a tokenizer loader", .timeLimit(.minutes(RealModelSuites.testTimeLimitMinutes)))
    struct MLXModelLoaderIntegrationTests {
        @Test(
            "a real load by name through MLXModelLoader(tokenizerLoader:) loads the tokenizer one time with that tokenizer loader",
            arguments: [IntegrationModels.llm, IntegrationModels.embedding])
        func aLoadUsesTheGivenTokenizerLoader(key: ModelPoolKey) async throws {
            try ModelAvailability.requireMetalDevice()
            let tokenizerLoader = RecordingTokenizerLoader()
            let pool = ModelPool(loader: MLXModelLoader(tokenizerLoader: tokenizerLoader))

            // The hold goes at once, thus the eviction job follows the load.
            _ = try await pool.acquire(key)
            try await IntegrationModels.waitForEviction(of: key, in: pool)

            #expect(await tokenizerLoader.directories.events.count == tokenizerLoadsOfOneModelLoad)
        }

        @Test(
            "a real load by name opens one load span, and one child span of the right parent for each phase, with no cache path",
            arguments: [IntegrationModels.llm, IntegrationModels.embedding])
        func aLoadOpensItsPhaseSpans(key: ModelPoolKey) async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let spans = try await TelemetryCapture.run(forbidding: [HubCache.default.cacheDirectory.path]) { context in
                // The hold goes at once, thus the eviction job follows the load.
                _ = try await pool.acquire(key)
                try await IntegrationModels.waitForEviction(of: key, in: pool)
                return context.spans
            }

            let load = try onlySpan(named: ExtrasTelemetry.SpanName.modelLoad, in: spans)
            #expect(load.attributes.get(ExtrasTelemetry.AttributeKey.modelRef) == .string(key.ref.stringValue))
            #expect(
                load.attributes.get(ExtrasTelemetry.AttributeKey.modelRevision)
                    == .string(MLXModelLoader.revision(of: key)))
            #expect(
                load.attributes.get(ExtrasTelemetry.AttributeKey.modelRole)
                    == .string(ExtrasTelemetry.telemetryRole(of: key.role)))
            for expected in phaseParents(of: key.role) {
                let phase = try onlySpan(named: expected.phase, in: spans)
                let parent = try onlySpan(named: expected.parent, in: spans)
                #expect(phase.parentSpanID == parent.spanID, "the parent of \(expected.phase)")
                #expect(phase.traceID == load.traceID, "the trace of \(expected.phase)")
            }
        }
    }
}
