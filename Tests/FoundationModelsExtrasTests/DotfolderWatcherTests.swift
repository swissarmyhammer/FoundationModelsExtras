import FixtureSupport
import Foundation
import Synchronization
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `DotfolderWatcher`: a create, an edit and a delete
/// under a watched root each give exactly one callback, a burst of events
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
/// The tests give the file system events by hand, through a
/// ``FakeWatchSources`` in place of the `DispatchSource` values of the
/// watcher, and end the quiet period by hand, through a
/// ``ManualDebounceTimer``. The file work of a test is real, because the
/// watcher reads the disk when it builds its watch tree. Each event and each
/// timer runs on the queue of the watcher before the call that gives it
/// returns, thus each count is final when a test reads it. No test waits for
/// the OS, and no test reads a clock.
///
/// The tests that need the real events of the OS are in the
/// `DotfolderWatcherIntegrationTests` suite of the `IntegrationTests`
/// package.
@Suite struct DotfolderWatcherTests {
  /// The debounce interval of each watcher under test. The manual debounce
  /// timer never counts it: the test ends the quiet period itself.
  private static let testDebounceInterval: DispatchTimeInterval = .milliseconds(150)

  /// How many times the burst test writes the document.
  private static let burstWriteCount = 5

  /// How many sources the burst test fires for each write: the entry folder
  /// and the document.
  private static let burstFiresPerWrite = 2

  /// How many callbacks the test of the stop from inside `onChange` counts
  /// at its end: one for the change before the stop, and one for the change
  /// after the start again.
  private static let callbacksAfterTheStartAgain = 2

  /// The number of callbacks that shows that the watcher reported the edit
  /// that the test made inside `onChange`: one for the flush that holds the
  /// edit, and one for the edit.
  private static let callbacksWithTheEditInsideOnChange = 2

  /// The name of the document that each fixture writes in an entry folder.
  private static let documentName = "document.md"

  // MARK: - Create, edit and delete each give exactly one callback

  @Test func creatingAFileGivesExactlyOneCoalescedCallback() async throws {
    try await Self.withWatchedTempRoot { root, signals in
      try Self.writeDocument(named: "new-entry", in: root)
      Self.expectExactlyOneSignal(signals, since: 0, afterEventsAt: [root])
    }
  }

  @Test func editingAFileGivesExactlyOneCoalescedCallback() async throws {
    try await Self.withWatchedTempRoot { root, signals in
      try Self.writeDocument(named: "existing-entry", in: root)
      let baseline = Self.expectExactlyOneSignal(signals, since: 0, afterEventsAt: [root])

      try Self.writeDocument(named: "existing-entry", in: root, bodySuffix: "edited")
      Self.expectExactlyOneSignal(signals, since: baseline, afterEventsAt: [Self.entry("existing-entry", in: root)])
    }
  }

  @Test func deletingAFileGivesExactlyOneCoalescedCallback() async throws {
    try await Self.withWatchedTempRoot { root, signals in
      try Self.writeDocument(named: "doomed-entry", in: root)
      let baseline = Self.expectExactlyOneSignal(signals, since: 0, afterEventsAt: [root])

      try FileManager.default.removeItem(at: Self.entry("doomed-entry", in: root))
      Self.expectExactlyOneSignal(signals, since: baseline, afterEventsAt: [root])
    }
  }

  // MARK: - Burst coalescing

  @Test func burstOfEventsInsideTheDebounceWindowGivesExactlyOneCallback() async throws {
    try await Self.withWatchedTempRoot { root, signals in
      // The first flush makes the watch tree again, thus the entry folder
      // and the document each have a source of their own before the burst
      // starts.
      try Self.writeDocument(named: "burst-entry", in: root)
      let baseline = Self.expectExactlyOneSignal(signals, since: 0, afterEventsAt: [root])

      let entry = Self.entry("burst-entry", in: root)
      let document = entry.appendingPathComponent(Self.documentName)
      for iteration in 0..<Self.burstWriteCount {
        try Self.documentContents(named: "burst-entry", bodySuffix: "rev\(iteration)")
          .write(to: document, atomically: true, encoding: .utf8)
        #expect(signals.sources.fireEvent(at: document))
        #expect(signals.sources.fireEvent(at: entry))
      }

      // Each event started a timer. A watcher that did not make each earlier
      // timer stale gives one callback for each timer, and the count after
      // the quiet period is then more than one.
      #expect(signals.timer.pendingCount == Self.burstWriteCount * Self.burstFiresPerWrite)
      #expect(signals.recorder.count == baseline)
      signals.timer.endQuietPeriod()
      #expect(signals.recorder.count == baseline + 1)
    }
  }

  // MARK: - Recursion: a new subdirectory and a change at depth both count

  @Test func aFileTwoLevelsDeepIsSeen() async throws {
    try await Self.withWatchedTempRoot { root, signals in
      // The write makes a new subdirectory and a file in it with one call.
      try Self.writeDocument(named: "nested-entry", in: root)
      let baseline = Self.expectExactlyOneSignal(signals, since: 0, afterEventsAt: [root])

      // The flush watched the new subdirectory recursively, thus the file
      // two levels under the root has a source of its own.
      let document = Self.entry("nested-entry", in: root).appendingPathComponent(Self.documentName)
      Self.expectExactlyOneSignal(signals, since: baseline, afterEventsAt: [document])
    }
  }

  @Test func editingAFileInAnExistingSubdirectoryIsSeen() async throws {
    try await Self.withWatchedTempRoot { root, signals in
      let subdirectory = root.appendingPathComponent("_partials", isDirectory: true)
      try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
      let baseline = Self.expectExactlyOneSignal(signals, since: 0, afterEventsAt: [root])

      try "header text".write(
        to: subdirectory.appendingPathComponent("header.md"), atomically: true, encoding: .utf8)
      Self.expectExactlyOneSignal(signals, since: baseline, afterEventsAt: [subdirectory])
    }
  }

  // MARK: - A directory that the watcher does not filter still coalesces

  @Test func eventsUnderAGitDirectoryCoalesceAndDoNotCrash() async throws {
    try await Self.withWatchedTempRoot { root, signals in
      let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
      try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
      let baseline = Self.expectExactlyOneSignal(signals, since: 0, afterEventsAt: [root])

      try "ref: refs/heads/main\n".write(
        to: gitDirectory.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
      Self.expectExactlyOneSignal(signals, since: baseline, afterEventsAt: [gitDirectory])
    }
  }

  // MARK: - A root that is not there

  @Test func aRootThatIsNotThereIsSkippedWithNoError() async throws {
    try await Self.withTempDirectory { privateDirectory in
      let missingRoot = privateDirectory.appendingPathComponent("does-not-exist", isDirectory: true)
      try await Self.withTempDirectory { realRoot in
        try await Self.withWatcher(over: [missingRoot, realRoot]) { signals in
          // The missing root is armed at its nearest existing ancestor.
          #expect(signals.sources.isLive(at: privateDirectory))

          try Self.writeDocument(named: "still-works", in: realRoot)
          Self.expectExactlyOneSignal(signals, since: 0, afterEventsAt: [realRoot])
        }
      }
    }
  }

  // MARK: - A root that appears later, armed at its nearest existing ancestor

  @Test func makingARootThatWasNotThereAtStartIsSeen() async throws {
    try await Self.withTempDirectory { privateDirectory in
      let lateRoot = privateDirectory.appendingPathComponent("arrives-later", isDirectory: true)
      try await Self.withWatcher(over: [lateRoot]) { signals in
        #expect(!signals.sources.isLive(at: lateRoot))

        try Self.writeDocument(named: "arrived-entry", in: lateRoot)
        Self.expectExactlyOneSignal(signals, since: 0, afterEventsAt: [privateDirectory])

        // The flush escalated to the real recursive watch of the root.
        #expect(signals.sources.isLive(at: lateRoot))
      }
    }
  }

  @Test func deletingAndMakingARootAgainKeepsTheEventsFlowing() async throws {
    try await Self.withTempDirectory { privateDirectory in
      let root = privateDirectory.appendingPathComponent("comes-and-goes", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try await Self.withWatcher(over: [root]) { signals in
        try Self.writeDocument(named: "before-delete", in: root)
        let afterFirstCreate = Self.expectExactlyOneSignal(signals, since: 0, afterEventsAt: [root])

        try FileManager.default.removeItem(at: root)
        let afterDelete = Self.expectExactlyOneSignal(signals, since: afterFirstCreate, afterEventsAt: [root])

        // The root is gone, thus the rebuild of `flush()` must have armed
        // `privateDirectory`, which is the nearest existing ancestor now,
        // and not stopped to watch anything at all.
        #expect(signals.sources.isLive(at: privateDirectory))
        try Self.writeDocument(named: "after-recreate", in: root)
        Self.expectExactlyOneSignal(signals, since: afterDelete, afterEventsAt: [privateDirectory])
      }
    }
  }

  @Test func editingAFileUnderARootThatAppearedLaterFiresAfterTheEscalation() async throws {
    try await Self.withTempDirectory { privateDirectory in
      let lateRoot = privateDirectory.appendingPathComponent("arrives-later", isDirectory: true)
      try await Self.withWatcher(over: [lateRoot]) { signals in
        try Self.writeDocument(named: "arrived-entry", in: lateRoot)
        let afterCreate = Self.expectExactlyOneSignal(signals, since: 0, afterEventsAt: [privateDirectory])

        // The flush above made the watch tree again, thus `lateRoot` is
        // watched recursively now. An edit two levels under it never
        // touches `privateDirectory`, thus only the recursive watch can
        // see it. The ancestor watch alone cannot.
        try Self.writeDocument(named: "arrived-entry", in: lateRoot, bodySuffix: "edited")
        Self.expectExactlyOneSignal(
          signals, since: afterCreate, afterEventsAt: [Self.entry("arrived-entry", in: lateRoot)])
      }
    }
  }

  @Test func unrelatedWorkUnderAnArmedAncestorGivesNoCallback() async throws {
    try await Self.withTempDirectory { privateDirectory in
      let lateRoot = privateDirectory.appendingPathComponent("arrives-later", isDirectory: true)
      try await Self.withWatcher(over: [lateRoot]) { signals in
        // `privateDirectory` is the armed ancestor. Work directly under it
        // that does not make `lateRoot` must not reach `onChange`: the
        // ancestor filter must drop each event before it starts a timer.
        let unrelated = privateDirectory.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        #expect(signals.sources.fireEvent(at: privateDirectory))
        try FileManager.default.removeItem(at: unrelated)
        #expect(signals.sources.fireEvent(at: privateDirectory))
        #expect(signals.timer.pendingCount == 0)
        #expect(signals.recorder.count == 0)

        // Making the awaited root itself still fires.
        try Self.writeDocument(named: "arrived-entry", in: lateRoot)
        Self.expectExactlyOneSignal(signals, since: 0, afterEventsAt: [privateDirectory])
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
        #expect(signals.sources.isLive(at: privateDirectory))

        // The write makes the full chain with one call, thus `a` appears
        // directly under the armed ancestor, which is the awaited child.
        try Self.writeDocument(named: "deep-entry", in: deepRoot)
        let afterCreate = Self.expectExactlyOneSignal(signals, since: 0, afterEventsAt: [privateDirectory])

        // The flush above escalated to a real recursive watch of
        // `deepRoot`. An edit four levels below `privateDirectory` is
        // visible through that watch only.
        try Self.writeDocument(named: "deep-entry", in: deepRoot, bodySuffix: "edited")
        Self.expectExactlyOneSignal(
          signals, since: afterCreate, afterEventsAt: [Self.entry("deep-entry", in: deepRoot)])
      }
    }
  }

  // MARK: - An unreadable directory inside a root

  @Test(.disabled(if: isRoot, "root reads a mode-0o000 directory, thus the unreadable branch is not reachable"))
  func anUnreadableDirectoryInsideARootIsSkippedAndItsReadableSiblingsStillReport() async throws {
    try await Self.withTempDirectory { root in
      let lockedDirectory = root.appendingPathComponent("locked", isDirectory: true)
      let lockedChild = lockedDirectory.appendingPathComponent("hidden", isDirectory: true)
      try FileManager.default.createDirectory(at: lockedChild, withIntermediateDirectories: true)
      try Self.setPosixPermissions(Self.unreadableMode, of: lockedDirectory)
      defer { try? Self.setPosixPermissions(Self.ownerAccessMode, of: lockedDirectory) }

      // `start()` lists `root`, reaches `locked`, and must take its failed
      // listing as "no entries", and not throw or leave the rest of the
      // tree.
      try await Self.withWatcher(over: [root]) { signals in
        #expect(!signals.sources.isLive(at: lockedChild))

        try Self.writeDocument(named: "readable-entry", in: root)
        Self.expectExactlyOneSignal(signals, since: 0, afterEventsAt: [root])
      }
    }
  }

  @Test func aPathThatTheWatcherCannotOpenIsSkippedAndItsSiblingsStillReport() async throws {
    try await Self.withTempDirectory { root in
      let refused = root.appendingPathComponent("refused", isDirectory: true)
      try FileManager.default.createDirectory(at: refused, withIntermediateDirectories: true)
      let sources = FakeWatchSources(refusing: [refused])

      try await Self.withWatcher(over: [root], sources: sources) { signals in
        #expect(!signals.sources.isLive(at: refused))
        #expect(signals.sources.isLive(at: root))

        try Self.writeDocument(named: "readable-entry", in: root)
        Self.expectExactlyOneSignal(signals, since: 0, afterEventsAt: [root])
      }
    }
  }

  // MARK: - A source that a later source replaces is cancelled, not leaked

  /// This test uses the real `DispatchSource` values and real descriptors.
  /// A cancel handler closes its descriptor later, on the queue of the
  /// watcher, thus the test waits for the descriptor count that each cancel
  /// handler reports. The cancel handler is an event of Dispatch, and not of
  /// the file system, thus the wait has an end.
  @Test func aRootThatComesBeforeItsOwnParentLeaksNoDescriptor() async throws {
    try await Self.withTempDirectory { parent in
      let missingChild = parent.appendingPathComponent("missing-child", isDirectory: true)
      let descriptorCounts = Recorder<Int>()
      let watcher = DotfolderWatcher(
        roots: [missingChild, parent], debounceInterval: Self.testDebounceInterval,
        startDebounceTimer: ManualDebounceTimer().start, openWatchSource: DotfolderWatcher.openDispatchSource,
        descriptorCountDidChange: { descriptorCounts.append($0) }, onChange: {})
      watcher.start()

      // Arming `missingChild` opens a source on `parent` first, and the
      // recursive watch of `parent` then replaces it. The replaced source
      // must be cancelled, thus its cancel handler closes the descriptor:
      // one open descriptor for each stored source, no more. `start()`
      // opened each source before it returned, thus the count is one more
      // than the stored sources until the cancel handler runs.
      let watchedSources = watcher.watchedSourceCountForTesting
      await descriptorCounts.waitUntil { $0.last == watchedSources }
      #expect(watcher.openDescriptorCountForTesting == watchedSources)

      watcher.stop()
      await descriptorCounts.waitUntil { $0.last == 0 }
      #expect(watcher.openDescriptorCountForTesting == 0)
    }
  }

  // MARK: - A change made while onChange runs is not lost

  /// A consumer that sees a reload can change a file immediately, while the
  /// watcher is still in the flush that made the reload. The event of that
  /// edit comes here inside `onChange`, thus it is in that flush. A watcher
  /// that opens its new sources after `onChange` only drops the event: the
  /// old sources are cancelled, and no new source is open yet.
  @Test func aChangeMadeWhileOnChangeRunsIsReportedAfterTheFlush() async throws {
    try await Self.withTempDirectory { root in
      try Self.writeDocument(named: "edited-in-flush", in: root)
      let entry = Self.entry("edited-in-flush", in: root)
      let edit = OneTimeEdit(entryName: "edited-in-flush", root: root)
      let sources = FakeWatchSources()
      let delivered = Mutex<Bool?>(nil)
      let editAndReport: @Sendable () -> Void = {
        guard edit.run() else { return }
        let wasDelivered = sources.fireEventOnTheWatcherQueue(at: entry)
        delivered.withLock { $0 = wasDelivered }
      }

      try await Self.withWatcher(over: [root], sources: sources, duringOnChange: editAndReport) { signals in
        try Self.writeDocument(named: "edited-in-flush", in: root, bodySuffix: "first edit")
        #expect(signals.sources.fireEvent(at: entry))

        // The edit inside `onChange` starts a new timer, and
        // `endQuietPeriod()` fires that timer in the same call.
        signals.timer.endQuietPeriod()
        #expect(edit.failure == nil)
        #expect(delivered.withLock { $0 } == true)
        #expect(signals.recorder.count == Self.callbacksWithTheEditInsideOnChange)
      }
    }
  }

  // MARK: - Stop ends the callbacks

  @Test func stopEndsTheCallbacksAfterAChange() async throws {
    try await Self.withWatchedTempRoot { root, signals in
      signals.stopWatcher()
      #expect(signals.sources.liveCount == 0)

      // An event that was on its way when the source was cancelled still
      // calls the handler. The stopped watcher must start no timer for it.
      try Self.writeDocument(named: "after-stop", in: root)
      #expect(!signals.sources.fireEvent(at: root))
      signals.sources.fireEventOfACancelledSource(at: root)
      #expect(signals.timer.pendingCount == 0)
      signals.timer.endQuietPeriod()
      #expect(signals.recorder.count == 0)
    }
  }

  // MARK: - A stop from inside onChange

  @Test func aStopFromInsideOnChangeStopsTheWatcherAndLeavesItStartableAgain() async throws {
    try await Self.withTempDirectory { root in
      let recorder = SignalRecorder()
      let timer = ManualDebounceTimer()
      let sources = FakeWatchSources()
      let box = WatcherBox()
      box.watcher = DotfolderWatcher(
        roots: [root], debounceInterval: Self.testDebounceInterval, startDebounceTimer: timer.start,
        openWatchSource: sources.open, descriptorCountDidChange: nil
      ) {
        recorder.record()
        box.watcher?.stop()
      }
      box.watcher?.start()
      defer { box.watcher?.stop() }

      try Self.writeDocument(named: "self-stopping", in: root)
      #expect(sources.fireEvent(at: root))
      timer.endQuietPeriod()
      #expect(recorder.count == 1)

      // The reentrant `stop()` must have taken each source down, and not
      // only changed a flag: the sources that `flush()` opened before
      // `onChange` must not stay open under a watcher that was just told to
      // stop. It ran inside `onChange`, which shows that the reentrancy
      // guard does not deadlock.
      #expect(box.watcher?.watchedSourceCountForTesting == 0)
      #expect(sources.liveCount == 0)

      // A further change on the same root must thus give no second signal:
      // the watcher must be stopped already, and not about to stop.
      try Self.writeDocument(named: "must-not-be-seen", in: root)
      sources.fireEventOfACancelledSource(at: root)
      timer.endQuietPeriod()
      #expect(recorder.count == 1)

      // The same instance must start again after that, thus the reentrant
      // stop must not leave it unable to watch for ever.
      box.watcher?.start()
      try Self.writeDocument(named: "after-restart", in: root)
      #expect(sources.fireEvent(at: root))
      timer.endQuietPeriod()
      #expect(recorder.count == Self.callbacksAfterTheStartAgain)
    }
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
        let afterDefaults = Self.expectExactlyOneSignal(signals, since: 0, afterEventsAt: [defaultsRoot])

        try Self.writeDocument(named: "from-the-project-layer", in: projectRoot)
        Self.expectExactlyOneSignal(signals, since: afterDefaults, afterEventsAt: [projectRoot])
      }
    }
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

  /// The entry folder `name` under `directory`.
  ///
  /// - Parameters:
  ///   - name: The name of the entry folder.
  ///   - directory: The root that holds the entry.
  /// - Returns: The URL of the entry folder.
  private static func entry(_ name: String, in directory: URL) -> URL {
    directory.appendingPathComponent(name, isDirectory: true)
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
    let entryDirectory = entry(name, in: directory)
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
  /// `onChange` closure, which can run only after an event and the end of
  /// the quiet period, thus after that write. The two never race, but the
  /// compiler cannot see that order.
  // swiftlint:disable:next no_unchecked_sendable  The test writes the value one time before the watcher can call back, as the documentation above says.
  private final class WatcherBox: @unchecked Sendable {
    var watcher: DotfolderWatcher?
  }

  /// Counts each callback of the watcher that a test receives.
  ///
  /// The callback counts in its own call, thus the count is up to date when
  /// the callback returns.
  private final class SignalRecorder: Sendable {
    /// How many callbacks arrived.
    private let callbacks = Mutex(0)

    /// How many callbacks arrived.
    var count: Int { callbacks.withLock { $0 } }

    /// Counts one callback.
    func record() {
      callbacks.withLock { $0 += 1 }
    }
  }

  /// A debounce timer that a test ends by hand.
  ///
  /// `start` records each timer that the watcher starts and fires none of
  /// them by itself. `endQuietPeriod()` fires them. The length of the quiet
  /// period is thus a decision of the test, and not a race between the
  /// events of the test and the real clock.
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

    /// The closure to give to `DotfolderWatcher` as its debounce timer.
    var start: DotfolderWatcher.DebounceTimer {
      { [self] _, queue, fire in
        startedTimers.withLock { $0.append(StartedTimer(queue: queue, fire: fire)) }
      }
    }

    /// How many timers the watcher started that are not fired yet.
    var pendingCount: Int {
      startedTimers.withLock { $0.count }
    }

    /// Fires each started timer on its queue, in start order, until none is
    /// left.
    ///
    /// A flush, or an `onChange` call, can start one more timer while the
    /// earlier ones fire. That start makes the earlier ones stale, thus one
    /// pass is not sufficient. `sync` also makes sure that the flush, and
    /// the new watch tree that the flush makes, are complete when this
    /// method returns.
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
        defer { timers.removeAll() }
        return timers
      }
    }
  }

  /// The watch sources of a watcher under test, which give their events
  /// only when the test fires them.
  ///
  /// `open` stands in for `DotfolderWatcher.openDispatchSource`. It records
  /// each source that the watcher opens and opens no descriptor. A cancel
  /// stops the events of a source at once, and runs its cancel handler on
  /// the queue of the watcher later, as a `DispatchSource` does.
  ///
  /// A `Mutex` guards the list, thus the compiler checks the plain
  /// `Sendable` conformance.
  private final class FakeWatchSources: Sendable {
    /// One source that the watcher opened.
    private struct Source: Sendable {
      /// The path of the source, as the watcher gave it.
      let path: String

      /// The queue of the watcher.
      let queue: DispatchQueue

      /// The handlers of the source.
      let handlers: DotfolderWatcher.WatchSourceHandlers

      /// Whether the watcher cancelled the source.
      var isCancelled = false
    }

    /// Each source that the watcher opened, in open order.
    private let sources = Mutex<[Source]>([])

    /// The paths that `open` refuses, as a path that `open(_:_:)` cannot
    /// open.
    private let refusedPaths: Set<String>

    /// Makes the sources of one watcher.
    ///
    /// - Parameter refused: The paths that `open` refuses.
    init(refusing refused: [URL] = []) {
      refusedPaths = Set(refused.map(Self.normalizedPath(of:)))
    }

    /// The closure to give to `DotfolderWatcher` as its source factory.
    var open: DotfolderWatcher.OpenWatchSource {
      { [self] path, _, queue, handlers in
        guard !refusedPaths.contains(Self.normalizedPath(path)) else { return nil }
        let index = sources.withLock { sources -> Int in
          sources.append(Source(path: path, queue: queue, handlers: handlers))
          return sources.count - 1
        }
        return DotfolderWatcher.WatchSource { self.cancel(index) }
      }
    }

    /// How many sources are open and not cancelled.
    var liveCount: Int {
      sources.withLock { $0.filter { !$0.isCancelled }.count }
    }

    /// Whether a source that is not cancelled watches `url`.
    ///
    /// - Parameter url: The path to look for.
    /// - Returns: `true` when such a source exists.
    func isLive(at url: URL) -> Bool {
      !liveSources(at: url).isEmpty
    }

    /// Gives one event to each live source of `url`, on the queue of the
    /// watcher, and returns when the event handlers returned.
    ///
    /// - Parameter url: The path of the event.
    /// - Returns: `true` when a live source got the event.
    @discardableResult
    func fireEvent(at url: URL) -> Bool {
      let live = liveSources(at: url)
      for source in live {
        source.queue.sync(execute: source.handlers.onEvent)
      }
      return !live.isEmpty
    }

    /// Gives one event to each live source of `url` at once. Call it only
    /// from code that runs on the queue of the watcher, for example from
    /// inside `onChange`.
    ///
    /// - Parameter url: The path of the event.
    /// - Returns: `true` when a live source got the event.
    func fireEventOnTheWatcherQueue(at url: URL) -> Bool {
      let live = liveSources(at: url)
      for source in live {
        source.handlers.onEvent()
      }
      return !live.isEmpty
    }

    /// Gives one event to the newest cancelled source of `url`, on the
    /// queue of the watcher, as an event that was on its way when the
    /// watcher cancelled the source.
    ///
    /// - Parameter url: The path of the event.
    func fireEventOfACancelledSource(at url: URL) {
      let path = Self.normalizedPath(of: url)
      let cancelled = sources.withLock { sources in
        sources.last { $0.isCancelled && Self.normalizedPath($0.path) == path }
      }
      #expect(cancelled != nil, "no cancelled source watches \(path)")
      cancelled.map { $0.queue.sync(execute: $0.handlers.onEvent) }
    }

    /// The live sources of `url`.
    ///
    /// - Parameter url: The path to look for.
    /// - Returns: Each source of that path that is not cancelled.
    private func liveSources(at url: URL) -> [Source] {
      let path = Self.normalizedPath(of: url)
      return sources.withLock { sources in
        sources.filter { !$0.isCancelled && Self.normalizedPath($0.path) == path }
      }
    }

    /// Cancels the source at `index`: no event reaches it after this call,
    /// and its cancel handler runs on the queue of the watcher later.
    ///
    /// - Parameter index: The place of the source in the list.
    private func cancel(_ index: Int) {
      let source = sources.withLock { sources -> Source? in
        guard !sources[index].isCancelled else { return nil }
        sources[index].isCancelled = true
        return sources[index]
      }
      source.map { $0.queue.async(execute: $0.handlers.onCancel) }
    }

    /// The path of `url` in the one form that the fake compares.
    ///
    /// - Parameter url: The URL.
    /// - Returns: The standardized path.
    private static func normalizedPath(of url: URL) -> String {
      url.standardizedFileURL.path
    }

    /// The path `path` in the one form that the fake compares.
    ///
    /// - Parameter path: The path.
    /// - Returns: The standardized path.
    private static func normalizedPath(_ path: String) -> String {
      normalizedPath(of: URL(fileURLWithPath: path))
    }
  }

  /// What a test of a watcher with fake sources sees and controls: the
  /// callbacks that arrived, the end of the quiet period, the events of the
  /// sources, and the stop of the watcher.
  private struct WatchedSignals {
    /// The count of the `onChange` calls.
    let recorder: SignalRecorder

    /// The debounce timer of the watcher.
    let timer: ManualDebounceTimer

    /// The watch sources of the watcher.
    let sources: FakeWatchSources

    /// Stops the watcher.
    let stopWatcher: () -> Void
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

  /// Starts a watcher over `roots` with a manual debounce timer and fake
  /// sources, hands its signals to `body`, then stops the watcher in each
  /// case.
  ///
  /// - Parameters:
  ///   - roots: The roots to watch, in the order that the watcher receives
  ///     them.
  ///   - sources: The fake sources of the watcher. The default makes new
  ///     ones.
  ///   - work: More work that `onChange` does after it counts the callback,
  ///     on the queue of the watcher. The default does nothing.
  ///   - body: The body of the test, with the signals of the watcher.
  /// - Throws: The error of `body`.
  private static func withWatcher(
    over roots: [URL], sources: FakeWatchSources = FakeWatchSources(),
    duringOnChange work: @escaping @Sendable () -> Void = {},
    _ body: (WatchedSignals) async throws -> Void
  ) async throws {
    try await Self.withWatcher(
      sources: sources,
      made: { timer, recordSignal in
        DotfolderWatcher(
          roots: roots, debounceInterval: Self.testDebounceInterval, startDebounceTimer: timer.start,
          openWatchSource: sources.open, descriptorCountDidChange: nil
        ) {
          recordSignal()
          work()
        }
      }, body)
  }

  /// Starts a watcher over the layer roots of `stack` with a manual
  /// debounce timer and fake sources, hands its signals to `body`, then
  /// stops the watcher in each case.
  ///
  /// - Parameters:
  ///   - stack: The stack whose layer roots the watcher watches.
  ///   - body: The body of the test, with the signals of the watcher.
  /// - Throws: The error of `body`.
  private static func withWatcher(
    over stack: some DotfolderStacking, _ body: (WatchedSignals) async throws -> Void
  ) async throws {
    let sources = FakeWatchSources()
    try await Self.withWatcher(
      sources: sources,
      made: { timer, recordSignal in
        DotfolderWatcher(
          stack: stack, debounceInterval: Self.testDebounceInterval,
          startDebounceTimer: timer.start, openWatchSource: sources.open, onChange: recordSignal)
      }, body)
  }

  /// Starts the watcher that `makeWatcher` makes, hands its signals to
  /// `body`, then stops the watcher in each case.
  ///
  /// - Parameters:
  ///   - sources: The fake sources that the watcher opens.
  ///   - makeWatcher: Makes the watcher from the manual debounce timer and
  ///     the closure that counts one callback.
  ///   - body: The body of the test, with the signals of the watcher.
  /// - Throws: The error of `body`.
  private static func withWatcher(
    sources: FakeWatchSources,
    made makeWatcher: (ManualDebounceTimer, @escaping @Sendable () -> Void) -> DotfolderWatcher,
    _ body: (WatchedSignals) async throws -> Void
  ) async throws {
    let recorder = SignalRecorder()
    let timer = ManualDebounceTimer()
    let watcher = makeWatcher(timer) { recorder.record() }
    watcher.start()
    defer { watcher.stop() }
    try await body(
      WatchedSignals(recorder: recorder, timer: timer, sources: sources, stopWatcher: { watcher.stop() }))
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
    ///
    /// - Returns: `true` on the first call, which made the edit.
    @discardableResult
    func run() -> Bool {
      let isFirstCall = hasRun.withLock { hasRun in
        defer { hasRun = true }
        return !hasRun
      }
      guard isFirstCall else { return false }
      do {
        try DotfolderWatcherTests.writeDocument(
          named: entryName, in: root, bodySuffix: "edit inside onChange")
      } catch {
        failureText.withLock { $0 = String(describing: error) }
      }
      return true
    }
  }

  /// Expects that the events at `paths`, which the file work of the test
  /// immediately before would give, make exactly one new signal after
  /// `baseline`.
  ///
  /// The steps: give one event to each path, confirm that a live source got
  /// each event and that the events started a debounce timer but made no
  /// callback by themselves, end the quiet period, then confirm that the
  /// count is `baseline + 1`. Each step runs on the queue of the watcher
  /// before it returns, thus the count is final then and needs no wait.
  ///
  /// - Parameters:
  ///   - signals: The signals of the watcher under test.
  ///   - baseline: The count that the test saw before the action under
  ///     test.
  ///   - paths: The paths that get one event each, in order.
  /// - Returns: The settled count, for the `baseline` of a further action
  ///   in the same test.
  @discardableResult
  private static func expectExactlyOneSignal(
    _ signals: WatchedSignals, since baseline: Int, afterEventsAt paths: [URL]
  ) -> Int {
    for path in paths {
      #expect(signals.sources.fireEvent(at: path), "no live source watches \(path.path)")
    }
    #expect(signals.timer.pendingCount >= 1)
    #expect(signals.recorder.count == baseline)

    signals.timer.endQuietPeriod()
    let settled = signals.recorder.count
    #expect(settled == baseline + 1)
    return settled
  }
}
