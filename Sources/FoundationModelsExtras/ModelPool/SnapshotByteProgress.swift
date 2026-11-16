import Foundation
import Synchronization

/// The byte progress of the files of one snapshot download, as the progress
/// handler of a `Downloader` gets it: a `Progress` whose total is the bytes
/// of the files, and whose completed count is the bytes on the disk.
///
/// Each file has one count. A file whose blob the cache holds counts all its
/// bytes, and a file that downloads counts the bytes of its `.incomplete`
/// blob. The count of a file never decreases: the `.incomplete` blob starts
/// again from zero when the server refuses the range of a retry or ignores
/// it, and the count then keeps its maximum until the blob is larger. Thus
/// the progress never goes backward.
final class SnapshotByteProgress: Sendable {
    /// The bytes of each file, by path, and their sum.
    private struct Counts {
        /// The bytes of each file, by path.
        var bytesByPath: [String: Int64]
        /// The sum of the bytes of the files.
        var completedBytes: Int64
    }

    /// The bytes of all files.
    private let totalBytes: Int64

    /// The counts. The lock also keeps the reports in order.
    private let counts: Mutex<Counts>

    /// Gets each report.
    private let progressHandler: @Sendable (Progress) -> Void

    /// Makes a progress.
    ///
    /// - Parameters:
    ///   - totalBytes: The bytes of all files.
    ///   - bytesByPath: The bytes of each file on the disk at the start.
    ///   - progressHandler: Gets each report, under the lock of the
    ///     progress.
    init(
        totalBytes: Int64, bytesByPath: [String: Int64], progressHandler: @escaping @Sendable (Progress) -> Void
    ) {
        self.totalBytes = totalBytes
        counts = Mutex(Counts(bytesByPath: bytesByPath, completedBytes: bytesByPath.values.reduce(0, +)))
        self.progressHandler = progressHandler
    }

    /// Reports the bytes of all files.
    func report() {
        counts.withLock { counts in
            deliver(completedBytes: counts.completedBytes)
        }
    }

    /// Sets the bytes of one file, and reports the bytes of all files. A
    /// count that is less than the last count of the file does not change
    /// the count.
    ///
    /// - Parameters:
    ///   - bytes: The bytes of the file on the disk.
    ///   - path: The path of the file.
    func record(_ bytes: Int64, of path: String) {
        counts.withLock { counts in
            let lastBytes = counts.bytesByPath[path] ?? 0
            let bytes = max(bytes, lastBytes)
            counts.completedBytes += bytes - lastBytes
            counts.bytesByPath[path] = bytes
            deliver(completedBytes: counts.completedBytes)
        }
    }

    /// Gives one progress to the handler.
    ///
    /// - Parameter completedBytes: The bytes of all files on the disk.
    private func deliver(completedBytes: Int64) {
        let progress = Progress(totalUnitCount: totalBytes)
        progress.completedUnitCount = completedBytes
        progressHandler(progress)
    }
}
