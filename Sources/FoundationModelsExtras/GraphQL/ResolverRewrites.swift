import Synchronization

/// The rewrites that resolvers give in one run of a document: the items of `extensions.rewrites` that come after the
/// changes of the name rewrite.
///
/// A resolver adds a rewrite when it reads a value that the caller wrote in a different form than the canonical form,
/// for example an address alias. The item then tells the agent the canonical form. The run binds a new collector to
/// ``current`` (a task local), and the resolver adds to it with no `await`. A `Mutex` guards the list, and not an
/// actor, because each add is synchronous. The GraphQL engine resolves the fields of one run in child tasks, and a
/// child task reads the task local of its parent, so each add of the run reaches the same collector, from a
/// synchronous resolver and from an async resolver.
///
/// An add with no bound collector adds no rewrite.
public final class ResolverRewrites: Sendable {
    /// The collector of the run that runs now, or `nil` when no run binds one.
    @TaskLocal public static var current: ResolverRewrites?

    /// The rewrites that the resolvers added, in the order of the adds, with no repeat, behind a lock.
    private let rewrites = Mutex<[NameRewrite]>([])

    /// Makes an empty collector.
    public init() {}

    /// The rewrites that the resolvers added, in the order of the adds.
    public var list: [NameRewrite] {
        rewrites.withLock { rewrites in rewrites }
    }

    /// Adds one rewrite. A rewrite that is the same as a rewrite of the list is not added again, because one run can
    /// resolve the same value more than one time.
    ///
    /// - Parameter rewrite: The rewrite: `from` is the text that the caller wrote, `to` is the canonical form, and
    ///   `path` is the path of the value, for example `["sendMessage", "input", "to"]`.
    public func add(_ rewrite: NameRewrite) {
        rewrites.withLock { rewrites in
            guard !rewrites.contains(rewrite) else {
                return
            }
            rewrites.append(rewrite)
        }
    }
}
