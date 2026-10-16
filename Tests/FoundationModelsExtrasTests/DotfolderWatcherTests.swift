import FixtureSupport
import Foundation
import Synchronization
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `DotfolderWatcher`: a create, an edit and a delete
/// under a watched root each give exactly one callback, a burst of writes
/// gives the same one callback, a change two levels deep is seen, a new
/// subdirectory is seen, a root that is not there at `start()` is armed at
/// its nearest existing ancestor and unrelated work under that ancestor
/// stays quiet, an unreadable directory inside a root neither throws nor
/// silences its readable siblings, a root that comes before its own parent
/// leaks no descriptor, a change made inside `onChange` is not lost,
/// `stop()` ends delivery and is safe from inside `onChange`, a stopped
/// watcher starts again, and `init(stack:)` watches each layer root of a
/// stack.
///
/// The file system events come from the OS. No event of the watcher shows an
/// event that the OS never gives, thus each wait for an OS event has one
/// deadline (``waitForOSEvent(within:_:)``), and no poll. A check that an
/// event does NOT come gives the OS one quiet window
/// (``waitOutTheQuietWindow()``). With the manual debounce timer, a callback
/// comes only inside `endQuietPeriod()`, thus the count after that call is
/// final and needs no window.
@Suite struct DotfolderWatcherTests {
  /// The debounce interval of each watcher under test.
  ///
  /// A test that asserts "exactly one callback" gives the watcher a
  /// `ManualDebounceTimer`, and the watcher then never counts this
  /// interval: the test ends the quiet period itself. The file work of a
  /// test and the quiet period of the watcher thus do not race on the real
  /// clock, and a slow host cannot divide one burst into two callbacks.
  /// Only the tests of `stop()` and of the descriptor count use the real
  /// timer with this interval, and they assert no count that the speed of
  /// the host can change.
  private static let testDebounceInterval: DispatchTimeInterval = .milliseconds(150)

  /// How long a test waits for an expected event or callback before it
  /// counts the absence as a failure. The value is generous, to absorb the
  /// jitter of the scheduler and of the file system events. A longer wait
  /// can only make a test slower; it cannot change a result.
  private static let expectedSignalTimeout: Duration = .seconds(10)

  /// How long a test waits to confirm that something does NOT occur: no
  /// second callback after the expected one, and no timer start for work
  /// that the watcher must ignore.
  private static let noFurtherSignalWindow: Duration = .seconds(1)

  /// How many times the burst test writes the document.
  private static let burstWriteCount = 5

  /// The smallest number of debounce timer starts that the burst test waits
  /// for before it ends the quiet period. The entry folder and the document
  /// each have a source of their own, and the burst changes the two, thus
  /// the watcher starts a timer two times or more. Fewer than two starts
  /// cannot show that a later start replaces an earlier one.
  private static let burstTimerStartFloor = 2

  /// How many callbacks the test of the stop from inside `onChange` counts
  /// at its end: one for the change before the stop, and one for the change
  /// after the start again.
  private static let callbacksAfterTheStartAgain = 2

  /// The name of the document that each fixture writes in an entry folder.
  private static let documentName = "document.md"

  // MARK: - Create, edit and delete each give exactly one callback

  @Test func creatingAFileGivesExactlyOneCoalescedCallback() async throws {
    try await Self.withWatchedTempRoot { root, signals in
      try Self.writeDocument(named: "new-entry", in: root)
      _ = await Self.expectExactlyOneSignal(signals, since: 0)
    }
  }

  @Test func editingAFileGivesExactlyOneCoalescedCallback() async throws {
    try await Self.withWatchedTempRoot { root, signals in
      try Self.writeDocument(named: "existing-entry", in: root)
      let baseline = await Self.expectExactlyOneSignal(signals, since: 0)

      try Self.writeDocument(named: "existing-entry", in: root, bodySuffix: "edited")
      _ = await Self.expectExactlyOneSignal(signals, since: baseline)
    }
  }

  @Test func deletingAFileGivesExactlyOneCoalescedCallback() async throws {
    try await Self.withWatchedTempRoot { root, signals in
      try Self.writeDocument(named: "doomed-entry", in: root)
      let baseline = await Self.expectExactlyOneSignal(signals, since: 0)

      try FileManager.default.removeItem(
        at: root.appendingPathComponent("doomed-entry", isDirectory: true))
      _ = await Self.expectExactlyOneSignal(signals, since: baseline)
    }
  }

  // MARK: - Burst coalescing

  @Test func burstOfWritesInsideTheDebounceWindowGivesExactlyOneCallback() async throws {
    try await Self.withWatchedTempRoot { root, signals in
      // The first flush makes the watch tree again, thus the entry folder
      // and the document each have a source of their own before the burst
      // starts.
      try Self.writeDocument(named: "burst-entry", in: root)
      let baseline = await Self.expectExactlyOneSignal(signals, since: 0)

      let documentFile = root
        .appendingPathComponent("burst-entry", isDirectory: true)
        .appendingPathComponent(Self.documentName)
      for iteration in 0..<Self.burstWriteCount {
        try Self.documentContents(named: "burst-entry", bodySuffix: "rev\(iteration)")
          .write(to: documentFile, atomically: true, encoding: .utf8)
      }

      // The quiet period ends only when the test says so, thus the full
      // burst is in one debounce window on a host of any speed. A watcher
      // that did not replace the earlier timer gives one callback for each
      // timer start, and this expectation fails.
      _ = await Self.expectExactlyOneSignal(
        signals, since: baseline, afterTimerStarts: Self.burstTimerStartFloor)
    }
  }

  // MARK: - Recursion: a new subdirectory and a change at depth both count

  @Test func aFileTwoLevelsDeepIsSeen() async throws {
    try await Self.withWatchedTempRoot { root, signals in
      // The write makes a new subdirectory and a file in it with one call.
      try Self.writeDocument(named: "nested-entry", in: root)
      _ = await Self.expectExactlyOneSignal(signals, since: 0)
    }
  }

  @Test func editingAFileInAnExistingSubdirectoryIsSeen() async throws {
    try await Self.withWatchedTempRoot { root, signals in
      let subdirectory = root.appendingPathComponent("_partials", isDirectory: true)
      try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
      let baseline = await Self.expectExactlyOneSignal(signals, since: 0)

      try "header text".write(
        to: subdirectory.appendingPathComponent("header.md"), atomically: true, encoding: .utf8)
      _ = await Self.expectExactlyOneSignal(signals, since: baseline)
    }
  }

  // MARK: - A directory that the watcher does not filter still coalesces

  @Test func eventsUnderAGitDirectoryCoalesceAndDoNotCrash() async throws {
    try await Self.withWatchedTempRoot { root, signals in
      let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
      try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
      let baseline = await Self.expectExactlyOneSignal(signals, since: 0)

      try "ref: refs/heads/main\n".write(
        to: gitDirectory.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
      _ = await Self.expectExactlyOneSignal(signals, since: baseline)
    }
  }

  // MARK: - A root that is not there

  @Test func aRootThatIsNotThereIsSkippedWithNoError() async throws {
    // The parent of `missingRoot` must be a private directory that this
    // test owns, and not the shared temporary directory: arming watches
    // the nearest EXISTING ancestor of the missing root, and the shared
    // temporary directory sees the unrelated work of each other test,
    // which would make the "exactly one signal" expectation below flaky.
    try await Self.withTempDirectory { privateDirectory in
      let missingRoot = privateDirectory.appendingPathComponent("does-not-exist", isDirectory: true)
      try await Self.withTempDirectory { realRoot in
        try await Self.withWatcher(over: [missingRoot, realRoot]) { signals in
          try Self.writeDocument(named: "still-works", in: realRoot)
          _ = await Self.expectExactlyOneSignal(signals, since: 0)
        }
      }
    }
  }

  // MARK: - A root that appears later, armed at its nearest existing ancestor

  @Test func makingARootThatWasNotThereAtStartIsSeen() async throws {
    try await Self.withTempDirectory { privateDirectory in
      let lateRoot = privateDirectory.appendingPathComponent("arrives-later", isDirectory: true)
      try await Self.withWatcher(over: [lateRoot]) { signals in
        try Self.writeDocument(named: "arrived-entry", in: lateRoot)
        _ = await Self.expectExactlyOneSignal(signals, since: 0)
      }
    }
  }

  @Test func deletingAndMakingARootAgainKeepsTheEventsFlowing() async throws {
    try await Self.withTempDirectory { privateDirectory in
      let root = privateDirectory.appendingPathComponent("comes-and-goes", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try await Self.withWatcher(over: [root]) { signals in
        try Self.writeDocument(named: "before-delete", in: root)
        let afterFirstCreate = await Self.expectExactlyOneSignal(signals, since: 0)

        try FileManager.default.removeItem(at: root)
        let afterDelete = await Self.expectExactlyOneSignal(signals, since: afterFirstCreate)

        // The root is gone, thus the rebuild of `flush()` must have armed
        // `privateDirectory`, which is the nearest existing ancestor now,
        // and not stopped to watch anything at all.
        try Self.writeDocument(named: "after-recreate", in: root)
        _ = await Self.expectExactlyOneSignal(signals, since: afterDelete)
      }
    }
  }

  @Test func editingAFileUnderARootThatAppearedLaterFiresAfterTheEscalation() async throws {
    try await Self.withTempDirectory { privateDirectory in
      let lateRoot = privateDirectory.appendingPathComponent("arrives-later", isDirectory: true)
      try await Self.withWatcher(over: [lateRoot]) { signals in
        try Self.writeDocument(named: "arrived-entry", in: lateRoot)
        let afterCreate = await Self.expectExactlyOneSignal(signals, since: 0)

        // The flush above made the watch tree again, thus `lateRoot` is
        // watched recursively now. An edit two levels under it never
        // touches `privateDirectory`, thus only the recursive watch can
        // see it. The ancestor watch alone cannot.
        try Self.writeDocument(named: "arrived-entry", in: lateRoot, bodySuffix: "edited")
        _ = await Self.expectExactlyOneSignal(signals, since: afterCreate)
      }
    }
  }

  @Test func unrelatedWorkUnderAnArmedAncestorGivesNoCallback() async throws {
    try await Self.withTempDirectory { privateDirectory in
      let lateRoot = privateDirectory.appendingPathComponent("arrives-later", isDirectory: true)
      try await Self.withWatcher(over: [lateRoot]) { signals in
        // `privateDirectory` is the armed ancestor. Work directly under it
        // that does not make `lateRoot` must not reach `onChange`.
        let unrelated = privateDirectory.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try "noise".write(
          to: unrelated.appendingPathComponent("noise.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: unrelated)
        // The ancestor filter must drop the noise before it starts a
        // debounce timer. With the manual timer, a callback count of zero
        // shows nothing by itself, thus the timer starts are the evidence.
        // The noise and the events of the root go to one source, thus no
        // later event can show that the noise started no timer: the test
        // gives the OS one quiet window.
        await Self.waitOutTheQuietWindow()
        #expect(signals.timer.pendingCount == 0)
        #expect(signals.recorder.count == 0)

        // Making the awaited root itself still fires.
        try Self.writeDocument(named: "arrived-entry", in: lateRoot)
        _ = await Self.expectExactlyOneSignal(signals, since: 0)
      }
    }
  }

  @Test func aRootSomeLevelsBelowItsNearestExistingAncestorIsArmedThere() async throws {
    try await Self.withTempDirectory { privateDirectory in
      // Only `privateDirectory` is there. The search for the ancestor must
      // walk up past `a/b/c`, which is three missing components, to find
      // it, and must not stop at the direct parent of the root, which is
      // missing too.
      let deepRoot = privateDirectory
        .appendingPathComponent("a", isDirectory: true)
        .appendingPathComponent("b", isDirectory: true)
        .appendingPathComponent("c", isDirectory: true)
        .appendingPathComponent("layer", isDirectory: true)
      try await Self.withWatcher(over: [deepRoot]) { signals in
        // The write makes the full chain with one call, thus `a` appears
        // directly under the armed ancestor, which is the awaited child.
        try Self.writeDocument(named: "deep-entry", in: deepRoot)
        let afterCreate = await Self.expectExactlyOneSignal(signals, since: 0)

        // The flush above escalated to a real recursive watch of
        // `deepRoot`. An edit four levels below `privateDirectory` is
        // visible through that watch only.
        try Self.writeDocument(named: "deep-entry", in: deepRoot, bodySuffix: "edited")
        _ = await Self.expectExactlyOneSignal(signals, since: afterCreate)
      }
    }
  }

  // MARK: - An unreadable directory inside a root

  @Test(.disabled(if: isRoot, "root reads a mode-0o000 directory, thus the unreadable branch is not reachable"))
  func anUnreadableDirectoryInsideARootIsSkippedAndItsReadableSiblingsStillReport() async throws {
    try await Self.withTempDirectory { root in
      let lockedDirectory = root.appendingPathComponent("locked", isDirectory: true)
      try FileManager.default.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
      try Self.setPosixPermissions(Self.unreadableMode, of: lockedDirectory)
      defer { try? Self.setPosixPermissions(Self.ownerAccessMode, of: lockedDirectory) }

      // `start()` lists `root`, reaches `locked`, and must take its failed
      // listing as "no entries", and not throw or leave the rest of the
      // tree.
      try await Self.withWatcher(over: [root]) { signals in
        try Self.writeDocument(named: "readable-entry", in: root)
        _ = await Self.expectExactlyOneSignal(signals, since: 0)
      }
    }
  }

  // MARK: - A source that a later source replaces is cancelled, not leaked

  @Test func aRootThatComesBeforeItsOwnParentLeaksNoDescriptor() async throws {
    try await Self.withTempDirectory { parent in
      let missingChild = parent.appendingPathComponent("missing-child", isDirectory: true)
      let (onChange, _) = Self.makeSignalRecorder()
      let watcher = DotfolderWatcher(
        roots: [missingChild, parent], debounceInterval: Self.testDebounceInterval, onChange: onChange)
      watcher.start()

      // Arming `missingChild` opens a source on `parent` first, and the
      // recursive watch of `parent` then replaces it. The replaced source
      // must be cancelled, thus its cancel handler closes the descriptor:
      // one open descriptor for each stored source, no more.
      await Self.waitForTheCancelHandlers(timeout: Self.expectedSignalTimeout) {
        watcher.openDescriptorCountForTesting == watcher.watchedSourceCountForTesting
      }
      #expect(watcher.openDescriptorCountForTesting == watcher.watchedSourceCountForTesting)

      watcher.stop()
      await Self.waitForTheCancelHandlers(timeout: Self.expectedSignalTimeout) {
        watcher.openDescriptorCountForTesting == 0
      }
      #expect(watcher.openDescriptorCountForTesting == 0)
    }
  }

  // MARK: - A change made while onChange runs is not lost

  /// A consumer that sees a reload can change a file immediately, while the
  /// watcher is still in the flush that made the reload. The edit here is
  /// made inside `onChange`, thus it is in that flush on a host of any
  /// speed. A watcher that opens its new sources after `onChange` only
  /// drops the event: the old sources are cancelled with the event pending,
  /// and the new sources open after the edit.
  @Test func aChangeMadeWhileOnChangeRunsIsReportedAfterTheFlush() async throws {
    try await Self.withTempDirectory { root in
      try Self.writeDocument(named: "edited-in-flush", in: root)
      let edit = OneTimeEdit(entryName: "edited-in-flush", root: root)

      try await Self.withWatcher(over: [root], duringOnChange: edit.run) { signals in
        try Self.writeDocument(named: "edited-in-flush", in: root, bodySuffix: "first edit")
        await Self.waitForOSEvent { await signals.timer.waitForPendingTimers(atLeast: 1) }
        signals.timer.endQuietPeriod()

        // The edit inside `onChange` must start a new timer.
        // `endQuietPeriod()` fires that timer itself when the event arrives
        // before its loop ends, and the second callback is then the
        // evidence.
        await Self.waitForOSEvent {
          await Waits.untilFirstEnds(
            { await signals.timer.waitForPendingTimers(atLeast: 1) },
            { await signals.recorder.waitForCount(atLeast: Self.callbacksWithTheEditInsideOnChange) })
        }
        #expect(edit.failure == nil)
        #expect(Self.reportedTheEditInsideOnChange(signals))
      }
    }
  }

  // MARK: - Stop ends the callbacks

  @Test func stopEndsTheCallbacksAfterAChange() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? FileManager.default.removeItem(at: root) }

    let (onChange, recorder) = Self.makeSignalRecorder()
    let watcher = DotfolderWatcher(
      roots: [root], debounceInterval: Self.testDebounceInterval, onChange: onChange)
    watcher.start()
    watcher.stop()

    try Self.writeDocument(named: "after-stop", in: root)
    await Self.waitOutTheQuietWindow()
    #expect(recorder.count == 0)
  }

  // MARK: - A stop from inside onChange

  @Test func aStopFromInsideOnChangeStopsTheWatcherAndLeavesItStartableAgain() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? FileManager.default.removeItem(at: root) }

    let recorder = SignalRecorder()
    let box = WatcherBox()
    box.watcher = DotfolderWatcher(roots: [root], debounceInterval: Self.testDebounceInterval) {
      recorder.record()
      box.watcher?.stop()
    }
    box.watcher?.start()

    try Self.writeDocument(named: "self-stopping", in: root)
    await Self.waitForOSEvent { await recorder.waitForCount(atLeast: 1) }
    #expect(recorder.count == 1)

    // The reentrant `stop()` must have taken each source down, and not
    // only changed a flag: the sources that `flush()` opened before
    // `onChange` must not stay open under a watcher that was just told to
    // stop.
    #expect(box.watcher?.watchedSourceCountForTesting == 0)

    // The reentrant `stop()` above ran inside `onChange`, which shows that
    // the reentrancy guard does not deadlock. A further change on the same
    // root must thus give no second signal: the watcher must be stopped
    // already, and not about to stop.
    try Self.writeDocument(named: "must-not-be-seen", in: root)
    await Self.waitOutTheQuietWindow()
    #expect(recorder.count == 1)

    // The same instance must start again after that, thus the reentrant
    // stop must not leave it unable to watch for ever.
    box.watcher?.start()
    defer { box.watcher?.stop() }
    try Self.writeDocument(named: "after-restart", in: root)
    await Self.waitForOSEvent { await recorder.waitForCount(atLeast: Self.callbacksAfterTheStartAgain) }
    #expect(recorder.count == Self.callbacksAfterTheStartAgain)
  }

  // MARK: - The layer roots of a stack

  @Test func aWatcherOverAStackReportsAChangeUnderEachLayerRoot() async throws {
    try await Self.withTempDirectory { home in
      let defaultsRoot = home.appendingPathComponent("defaults", isDirectory: true)
      let projectRoot = home.appendingPathComponent("project", isDirectory: true)
      for root in [defaultsRoot, projectRoot] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      }
      let stack = DotfolderStack(layers: [
        DotfolderStack.Layer(source: .defaults, root: defaultsRoot),
        DotfolderStack.Layer(source: .project, root: projectRoot),
      ])

      try await Self.withWatcher(over: stack) { signals in
        try Self.writeDocument(named: "from-the-defaults-layer", in: defaultsRoot)
        let afterDefaults = await Self.expectExactlyOneSignal(signals, since: 0)

        try Self.writeDocument(named: "from-the-project-layer", in: projectRoot)
        _ = await Self.expectExactlyOneSignal(signals, since: afterDefaults)
      }
    }
  }

  // MARK: - README example

  /// Mirrored in the `DotfolderWatcher` section of README.md. Keep the two
  /// in sync.
  ///
  /// Makes the watcher that the README shows over a stack whose project
  /// layer is not there yet, then makes that layer and waits for the
  /// callback, thus the README cannot go stale without a test that fails.
  /// The test binds `workingDirectory` and `userDirectory` to one temporary
  /// folder, thus it touches no home directory.
  ///
  /// This test uses the real debounce timer, because the README shows the
  /// public initializer. It waits for an expected callback only, thus a
  /// slow host makes it slower and cannot change its result.
  @Test func readmeStackWatcherExample() async throws {
    let home = try TemporaryDirectory.make()
    defer { try? FileManager.default.removeItem(at: home) }
    let workingDirectory = home.appendingPathComponent("project", isDirectory: true)
    let userDirectory = home.appendingPathComponent("config", isDirectory: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    let (reload, recorder) = Self.makeSignalRecorder()

    let stack = DotfolderStack(
      name: "myagent", workingDirectory: workingDirectory, userDirectory: userDirectory)

    let watcher = DotfolderWatcher(stack: stack) {
      // A layer changed on disk. The stack holds no cache, thus the next
      // lookup gives the new files.
      reload()
    }
    watcher.start()
    defer { watcher.stop() }

    try Self.writeDocument(
      named: "new-entry", in: workingDirectory.appendingPathComponent(".myagent", isDirectory: true))
    await Self.waitForOSEvent { await recorder.waitForCount(atLeast: 1) }
    #expect(recorder.count >= 1)
  }

  // MARK: - Test helpers

  /// The file mode that refuses each read, thus a directory listing fails.
  private static let unreadableMode = 0o000

  /// The file mode that the teardown puts back, thus the temporary
  /// directory can be removed.
  private static let ownerAccessMode = 0o700

  /// Whether the test process is root. Root reads a mode-`0o000`
  /// directory, thus the test of the unreadable directory cannot reach the
  /// branch that it covers and is skipped there.
  private static var isRoot: Bool { geteuid() == 0 }

  /// Sets the POSIX permission bits of `item`.
  ///
  /// - Parameters:
  ///   - mode: The permission bits to apply.
  ///   - item: The file or the directory to change.
  /// - Throws: The error of `FileManager.setAttributes`.
  private static func setPosixPermissions(_ mode: Int, of item: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: item.path)
  }

  /// Writes `<directory>/<name>/document.md`, and makes the entry folder
  /// first when it is not there.
  ///
  /// - Parameters:
  ///   - name: The name of the entry folder.
  ///   - directory: The root to write under.
  ///   - bodySuffix: Text that the body ends with, thus two writes of one
  ///     name give two different texts.
  /// - Throws: The error of `FileManager.createDirectory` or of
  ///   `String.write`.
  private static func writeDocument(
    named name: String, in directory: URL, bodySuffix: String = ""
  ) throws {
    let entryDirectory = directory.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: entryDirectory, withIntermediateDirectories: true)
    try Self.documentContents(named: name, bodySuffix: bodySuffix)
      .write(
        to: entryDirectory.appendingPathComponent(Self.documentName), atomically: true,
        encoding: .utf8)
  }

  /// The text of the document of an entry.
  ///
  /// - Parameters:
  ///   - name: The name of the entry folder.
  ///   - bodySuffix: Text that the body ends with.
  /// - Returns: The full text of the document.
  private static func documentContents(named name: String, bodySuffix: String = "") -> String {
    "Body text for \(name). \(bodySuffix)\n"
  }

  /// A cell that holds the `DotfolderWatcher` under test, thus its own
  /// `onChange` closure can call back into it.
  ///
  /// `@unchecked Sendable`: the test writes `watcher` one time, right after
  /// the watcher is made and before `start()` runs. Each read is inside the
  /// `onChange` closure, which can run only after a file system event and
  /// the debounce delay, thus after that write. The two never race, but the
  /// compiler cannot see that order.
  // swiftlint:disable:next no_unchecked_sendable  The test writes the value one time before the watcher can call back, as the documentation above says.
  private final class WatcherBox: @unchecked Sendable {
    var watcher: DotfolderWatcher?
  }

  /// Counts each callback of the watcher that a test receives.
  ///
  /// The callback counts in its own call, with no task hop, thus the count
  /// is up to date when the callback returns. A wait for a count needs no
  /// poll: each callback ends the waits that its count meets.
  private final class SignalRecorder: Sendable {
    /// One value for each callback.
    private let callbacks = Recorder<Void>()

    /// How many callbacks arrived.
    var count: Int { callbacks.values.count }

    /// Counts one callback.
    func record() {
      callbacks.append(())
    }

    /// Waits until at least `target` callbacks arrived, or until the task
    /// is cancelled.
    ///
    /// - Parameter target: The count to wait for.
    func waitForCount(atLeast target: Int) async {
      await callbacks.waitUntil { $0.count >= target }
    }
  }

  /// A debounce timer that a test ends by hand.
  ///
  /// `start` records each timer that the watcher starts and fires none of
  /// them by itself. `endQuietPeriod()` fires them. The length of the quiet
  /// period is thus a decision of the test, and not a race between the file
  /// work of the test and the real clock.
  ///
  /// A `Mutex` guards the list, thus the compiler checks the plain
  /// `Sendable` conformance.
  private final class ManualDebounceTimer: Sendable {
    /// One timer that the watcher started: the queue to fire on, and the
    /// closure to fire.
    private struct StartedTimer: Sendable {
      let queue: DispatchQueue
      let fire: @Sendable () -> Void
    }

    /// The timers that the watcher started and `endQuietPeriod()` did not
    /// fire yet, in start order.
    private let startedTimers = Mutex<[StartedTimer]>([])

    /// The count of the timers that are not fired yet, after each change, in
    /// the order of the changes. A test waits on it for a timer start.
    private let pendingCounts = Recorder<Int>()

    /// The closure to give to `DotfolderWatcher` as its debounce timer.
    var start: DotfolderWatcher.DebounceTimer {
      { [self] _, queue, fire in
        startedTimers.withLock { timers in
          timers.append(StartedTimer(queue: queue, fire: fire))
          pendingCounts.append(timers.count)
        }
      }
    }

    /// How many timers the watcher started that are not fired yet.
    var pendingCount: Int {
      startedTimers.withLock { $0.count }
    }

    /// Waits until at least `count` timers are not fired yet, or until the
    /// task is cancelled.
    ///
    /// - Parameter count: The count of timers to wait for.
    func waitForPendingTimers(atLeast count: Int) async {
      await pendingCounts.waitUntil { ($0.last ?? 0) >= count }
    }

    /// Fires each started timer on its queue, in start order, until none is
    /// left.
    ///
    /// An event that arrived immediately before this call can start one
    /// more timer while the earlier ones fire. That start makes the earlier
    /// ones stale, thus one pass is not sufficient. `sync` also makes sure
    /// that the flush, and the new watch tree that the flush makes, are
    /// complete when this method returns.
    func endQuietPeriod() {
      var due = takeStartedTimers()
      while !due.isEmpty {
        for timer in due {
          timer.queue.sync(execute: timer.fire)
        }
        due = takeStartedTimers()
      }
    }

    /// Removes and gives each timer that is not fired yet.
    ///
    /// - Returns: The timers, in start order.
    private func takeStartedTimers() -> [StartedTimer] {
      startedTimers.withLock { timers in
        defer {
          timers.removeAll()
          pendingCounts.append(0)
        }
        return timers
      }
    }
  }

  /// What a test of a watcher with a manual debounce timer sees and
  /// controls: the callbacks that arrived, and the end of the quiet period.
  private struct WatchedSignals {
    /// The count of the `onChange` calls.
    let recorder: SignalRecorder

    /// The debounce timer of the watcher.
    let timer: ManualDebounceTimer
  }

  /// Starts a watcher over a new temporary root, hands the root and its
  /// signals to `body`, then stops the watcher and removes the temporary
  /// directory in each case.
  ///
  /// - Parameter body: The body of the test, with the watched root and the
  ///   signals of the watcher.
  /// - Throws: The error of `body` or of the temporary directory.
  private static func withWatchedTempRoot(
    _ body: (URL, WatchedSignals) async throws -> Void
  ) async throws {
    try await Self.withTempDirectory { root in
      try await Self.withWatcher(over: [root]) { signals in
        try await body(root, signals)
      }
    }
  }

  /// Makes a new temporary directory, hands it to `body`, then removes it
  /// in each case.
  ///
  /// - Parameter body: The body of the test, with the directory.
  /// - Throws: The error of `body` or of the temporary directory.
  private static func withTempDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = try TemporaryDirectory.make()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
  }

  /// Starts a watcher over `roots` with a manual debounce timer, hands its
  /// signals to `body`, then stops the watcher in each case.
  ///
  /// - Parameters:
  ///   - roots: The roots to watch, in the order that the watcher receives
  ///     them.
  ///   - work: More work that `onChange` does after it counts the callback,
  ///     on the queue of the watcher. The default does nothing.
  ///   - body: The body of the test, with the signals of the watcher.
  /// - Throws: The error of `body`.
  private static func withWatcher(
    over roots: [URL], duringOnChange work: @escaping @Sendable () -> Void = {},
    _ body: (WatchedSignals) async throws -> Void
  ) async throws {
    try await Self.withWatcher(
      made: { timer, recordSignal in
        DotfolderWatcher(
          roots: roots, debounceInterval: Self.testDebounceInterval, startDebounceTimer: timer.start
        ) {
          recordSignal()
          work()
        }
      }, body)
  }

  /// Starts a watcher over the layer roots of `stack` with a manual
  /// debounce timer, hands its signals to `body`, then stops the watcher in
  /// each case.
  ///
  /// - Parameters:
  ///   - stack: The stack whose layer roots the watcher watches.
  ///   - body: The body of the test, with the signals of the watcher.
  /// - Throws: The error of `body`.
  private static func withWatcher(
    over stack: some DotfolderStacking, _ body: (WatchedSignals) async throws -> Void
  ) async throws {
    try await Self.withWatcher(
      made: { timer, recordSignal in
        DotfolderWatcher(
          stack: stack, debounceInterval: Self.testDebounceInterval,
          startDebounceTimer: timer.start, onChange: recordSignal)
      }, body)
  }

  /// Starts the watcher that `makeWatcher` makes, hands its signals to
  /// `body`, then stops the watcher in each case.
  ///
  /// - Parameters:
  ///   - makeWatcher: Makes the watcher from the manual debounce timer and
  ///     the closure that counts one callback.
  ///   - body: The body of the test, with the signals of the watcher.
  /// - Throws: The error of `body`.
  private static func withWatcher(
    made makeWatcher: (ManualDebounceTimer, @escaping @Sendable () -> Void) -> DotfolderWatcher,
    _ body: (WatchedSignals) async throws -> Void
  ) async throws {
    let (recordSignal, recorder) = Self.makeSignalRecorder()
    let timer = ManualDebounceTimer()
    let watcher = makeWatcher(timer, recordSignal)
    watcher.start()
    defer { watcher.stop() }
    try await body(WatchedSignals(recorder: recorder, timer: timer))
  }

  /// Edits the document of one entry the first time that `run()` is called,
  /// and does nothing on each later call.
  ///
  /// A test gives `run` to a watcher as work inside `onChange`. The edit is
  /// then in the flush that made the callback, and the first flush only
  /// makes an edit, thus the test has an end.
  ///
  /// A `Mutex` guards each value that changes, thus the compiler checks the
  /// plain `Sendable` conformance.
  private final class OneTimeEdit: Sendable {
    private let entryName: String
    private let root: URL
    private let hasRun = Mutex(false)
    private let failureText = Mutex<String?>(nil)

    /// The error text of an edit that failed, or `nil`.
    var failure: String? {
      failureText.withLock { $0 }
    }

    /// Makes an edit that writes the document of `entryName`.
    ///
    /// - Parameters:
    ///   - entryName: The name of the entry folder whose document the edit
    ///     writes.
    ///   - root: The watched root that holds the entry.
    init(entryName: String, root: URL) {
      self.entryName = entryName
      self.root = root
    }

    /// Writes the file on the first call only. The error of a write goes to
    /// `failure`, because `onChange` cannot throw.
    @Sendable func run() {
      let isFirstCall = hasRun.withLock { hasRun in
        defer { hasRun = true }
        return !hasRun
      }
      guard isFirstCall else { return }
      do {
        try DotfolderWatcherTests.writeDocument(
          named: entryName, in: root, bodySuffix: "edit inside onChange")
      } catch {
        failureText.withLock { $0 = String(describing: error) }
      }
    }
  }

  /// The number of callbacks that shows that the watcher reported the edit
  /// of a `OneTimeEdit`: one for the flush that holds the edit, and one for
  /// the edit.
  private static let callbacksWithTheEditInsideOnChange = 2

  /// Whether the watcher reported the edit that a `OneTimeEdit` made inside
  /// `onChange`: a debounce timer is pending, or the callback for the edit
  /// arrived already.
  ///
  /// - Parameter signals: The signals of the watcher under test.
  /// - Returns: `true` when the watcher reported the edit.
  private static func reportedTheEditInsideOnChange(_ signals: WatchedSignals) -> Bool {
    signals.timer.pendingCount >= 1 || signals.recorder.count >= Self.callbacksWithTheEditInsideOnChange
  }

  /// Makes an `onChange` closure together with the `SignalRecorder` that it
  /// feeds.
  ///
  /// - Returns: The closure to give as `onChange`, and the recorder that it
  ///   feeds.
  private static func makeSignalRecorder() -> (
    onChange: @Sendable () -> Void, recorder: SignalRecorder
  ) {
    let recorder = SignalRecorder()
    let onChange: @Sendable () -> Void = { recorder.record() }
    return (onChange, recorder)
  }

  /// Expects that the file work that the test did immediately before gives
  /// exactly one new signal after `baseline`.
  ///
  /// The steps: wait until the watcher started `minimumTimerStarts`
  /// debounce timers, confirm that the events made no callback by
  /// themselves, end the quiet period, then confirm that the count is
  /// `baseline + 1`. The manual timer fires only in `endQuietPeriod()`, and
  /// that call returns after each callback that it made, thus the count is
  /// final then and needs no wait.
  ///
  /// - Parameters:
  ///   - signals: The signals of the watcher under test.
  ///   - baseline: The count that the test saw before the action under
  ///     test.
  ///   - minimumTimerStarts: How many timer starts to wait for before the
  ///     quiet period ends.
  /// - Returns: The settled count, for the `baseline` of a further action
  ///   in the same test.
  @discardableResult
  private static func expectExactlyOneSignal(
    _ signals: WatchedSignals, since baseline: Int, afterTimerStarts minimumTimerStarts: Int = 1
  ) async -> Int {
    await Self.waitForOSEvent { await signals.timer.waitForPendingTimers(atLeast: minimumTimerStarts) }
    #expect(signals.timer.pendingCount >= minimumTimerStarts)
    #expect(signals.recorder.count == baseline)

    signals.timer.endQuietPeriod()
    let settled = signals.recorder.count
    #expect(settled == baseline + 1)
    return settled
  }

  /// Waits until `event` ends, or until `deadline` passes.
  ///
  /// The OS gives each file system event. When the OS gives no event, no
  /// other event shows it, thus this wait has one deadline and no poll. A
  /// test then reads the state, and an expectation fails.
  ///
  /// - Parameters:
  ///   - deadline: The longest wait. The default is
  ///     ``expectedSignalTimeout``.
  ///   - event: The wait for the event that the OS starts.
  private static func waitForOSEvent(
    within deadline: Duration = expectedSignalTimeout, _ event: @escaping @Sendable () async -> Void
  ) async {
    await Waits.untilFirstEnds(event, { try? await Task.sleep(for: deadline) })
  }

  /// Gives the OS ``noFurtherSignalWindow`` to show an event that must not
  /// come. No event shows an event that does not come, thus a check of an
  /// absence needs this one window.
  private static func waitOutTheQuietWindow() async {
    try? await Task.sleep(for: noFurtherSignalWindow)
  }

  /// How long the descriptor wait sleeps between two reads of its condition.
  private static let descriptorPollInterval: Duration = .milliseconds(10)

  /// Reads `condition` until it holds or `timeout` is complete.
  ///
  /// Only the descriptor test uses this poll. A cancel handler of a
  /// `DispatchSource` closes its descriptor later on the queue of the
  /// watcher, and no event tells when.
  ///
  /// - Parameters:
  ///   - timeout: How long to read before the wait ends.
  ///   - condition: The condition to wait for.
  private static func waitForTheCancelHandlers(timeout: Duration, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: Self.descriptorPollInterval)
    }
  }
}
