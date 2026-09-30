import Foundation
import MLXLMCommon
import Synchronization

/// A downloader that reports the progress of the downloads of an upstream
/// downloader as ``ModelLoadProgress``: one
/// ``ModelLoadProgress/downloading(completedBytes:totalBytes:)`` for each new
/// byte count of a download, and ``ModelLoadProgress/loading`` when a download
/// returns. ``MLXModelLoader`` gives it to the MLX model factories, which
/// download the files of the model and then load them.
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
    /// `progressHandler`, and reports its bytes as a download. When the
    /// download returns, reports all its bytes when the last report did not,
    /// and then reports the load.
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
        let counter = DownloadByteCounter(report: report)
        let directory = try await upstream.download(
            id: id, revision: revision, matching: patterns, useLatest: useLatest
        ) { progress in
            progressHandler(progress)
            counter.observe(progress: progress)
        }
        counter.reportAllBytes()
        report(.loading)
        return directory
    }
}

/// Turns the `Progress` values of one Hugging Face snapshot download into
/// ``ModelLoadProgress/downloading(completedBytes:totalBytes:)`` reports.
///
/// The progress of a snapshot counts bytes: its `totalUnitCount` is the sum of
/// the sizes of the files of the repository. Each file is a child progress.
/// The parent counts the bytes of a child in its `completedUnitCount` only
/// when the child ends, thus the completed bytes come from
/// `fractionCompleted`, which also counts the part of each file that
/// downloads now.
///
/// The counter reports a byte count one time, and never fewer completed bytes
/// than before. It reports nothing for a first progress that is complete: the
/// Hugging Face downloader gives one such progress, of one unit, when its
/// cache holds the snapshot, and no file downloads.
final class DownloadByteCounter: Sendable {
    /// The bytes of one report.
    private struct ByteCount: Equatable {
        /// The bytes that the download has.
        let completedBytes: Int64
        /// The bytes of the whole download.
        let totalBytes: Int64
    }

    /// The last report, or `nil` before the first. The lock also keeps the
    /// reports in order.
    private let lastCount = Mutex<ByteCount?>(nil)

    /// Gets each report.
    private let report: @Sendable (ModelLoadProgress) -> Void

    /// Makes a counter.
    ///
    /// - Parameter report: Gets each report, under the lock of the counter.
    init(report: @escaping @Sendable (ModelLoadProgress) -> Void) {
        self.report = report
    }

    /// Reports the bytes of `progress` when they are new.
    ///
    /// - Parameter progress: A progress of the snapshot download.
    func observe(progress: Progress) {
        let totalBytes = progress.totalUnitCount
        guard totalBytes > 0 else { return }
        let completedBytes = min(Int64((progress.fractionCompleted * Double(totalBytes)).rounded()), totalBytes)
        deliver(count: ByteCount(completedBytes: completedBytes, totalBytes: totalBytes))
    }

    /// Reports all bytes of the download when the last report did not. Call
    /// it when the download returns.
    func reportAllBytes() {
        guard let last = lastCount.withLock({ $0 }) else { return }
        deliver(count: ByteCount(completedBytes: last.totalBytes, totalBytes: last.totalBytes))
    }

    /// Reports `count` when it follows the last report. See
    /// ``shouldReport(count:after:)``.
    ///
    /// - Parameter count: The bytes of a progress.
    private func deliver(count: ByteCount) {
        lastCount.withLock { last in
            guard Self.shouldReport(count: count, after: last) else { return }
            last = count
            report(.downloading(completedBytes: count.completedBytes, totalBytes: count.totalBytes))
        }
    }

    /// Whether `count` is a new report after `last`: a first count that is not
    /// complete, or a later count that differs from `last` and has no fewer
    /// completed bytes.
    ///
    /// - Parameters:
    ///   - count: The bytes of a progress.
    ///   - last: The last report, or `nil` before the first.
    /// - Returns: Whether to report `count`.
    private static func shouldReport(count: ByteCount, after last: ByteCount?) -> Bool {
        guard let last else { return count.completedBytes < count.totalBytes }
        return count != last && count.completedBytes >= last.completedBytes
    }
}
