import Testing

@testable import Marketplace

/// Proves ``EventBroadcaster``: each subscriber sees every value that the
/// broadcaster publishes after the subscription, and no value from before it.
@Suite("Event broadcaster")
struct EventBroadcasterTests {
  /// The values that the publication tests publish, in order.
  private static let values = ["first", "second"]

  /// How many subscribers the drop test registers before it drops one.
  private static let twoSubscribers = 2

  @Test func eachSubscriberSeesEveryPublishedValueInOrder() async {
    let broadcaster = EventBroadcaster<String>()
    var one = broadcaster.subscribe().makeAsyncIterator()
    var two = broadcaster.subscribe().makeAsyncIterator()

    for value in Self.values {
      broadcaster.publish(value)
    }

    for value in Self.values {
      #expect(await one.next() == value)
      #expect(await two.next() == value)
    }
  }

  @Test func aSubscriptionTakenAfterAPublicationDoesNotSeeIt() async {
    let broadcaster = EventBroadcaster<String>()
    broadcaster.publish("before")

    var late = broadcaster.subscribe().makeAsyncIterator()
    broadcaster.publish("after")

    #expect(await late.next() == "after")
  }

  @Test func aPublicationWithNoSubscriberIsNotAnError() {
    let broadcaster = EventBroadcaster<String>()

    broadcaster.publish("unheard")

    #expect(broadcaster.subscriberCount == 0)
  }

  @Test func aDroppedSubscriberKeepsNoSlot() async {
    let broadcaster = EventBroadcaster<String>()
    var kept = broadcaster.subscribe().makeAsyncIterator()
    let droppedStream = broadcaster.subscribe()
    let dropped = Task { for await _ in droppedStream {} }
    #expect(broadcaster.subscriberCount == Self.twoSubscribers)

    dropped.cancel()
    await dropped.value
    broadcaster.publish("after")

    #expect(broadcaster.subscriberCount == 1)
    #expect(await kept.next() == "after")
  }
}
