import Foundation
import MLXLMCommon

/// A downloader that reports the progress of the downloads of an upstream
/// downloader as ``ModelLoadProgress``: one
/// ``ModelLoadProgress/downloading(fraction:)`` for each progress of a
/// download, and ``ModelLoadProgress/loading`` when a download returns.
/// ``MLXModelLoader`` gives it to the MLX model factories, which download the
/// files of the model and then load them.
struct ProgressReportingDownloader: Downloader {
    /// The downloader that downloads the files.
    private let upstream: any Downloader

    /// Gets each report.
    private let report: @Sendable (ModelLoadProgress) -> Void

    /// Makes a downloader over `upstream`.
    ///
    /// - Parameters:
    ///   - upstream: The downloader that downloads the files.
    ///   - report: Gets each report. It can run on any thread.
    init(upstream: any Downloader, report: @escaping @Sendable (ModelLoadProgress) -> Void) {
        self.upstream = upstream
        self.report = report
    }

    /// Downloads with the upstream downloader. Gives each progress to
    /// `progressHandler`, and reports it as a download. Reports the load when
    /// the download returns.
    ///
    /// - Parameters:
    ///   - id: The repository.
    ///   - revision: The revision, or `nil` for the default.
    ///   - patterns: The patterns of the files to download.
    ///   - useLatest: Whether to look for a newer revision when the cache holds
    ///     one.
    ///   - progressHandler: Gets each progress of the download.
    /// - Returns: The folder that holds the files.
    /// - Throws: The error of the upstream download.
    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let report = report
        let directory = try await upstream.download(
            id: id, revision: revision, matching: patterns, useLatest: useLatest
        ) { progress in
            progressHandler(progress)
            report(.downloading(fraction: progress.fractionCompleted))
        }
        report(.loading)
        return directory
    }
}
