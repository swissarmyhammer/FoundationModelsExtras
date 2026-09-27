@testable import FoundationModelsExtras
import Testing

/// ``SerialAsyncChain`` runs its deliveries one at a time, in the order of
/// the enqueue.
@Suite("SerialAsyncChain: one delivery at a time, first in, first out")
struct SerialAsyncChainTests {
    /// The number of deliveries that each test enqueues.
    private static let deliveryCount = 5

    /// The number of times each delivery yields between its start and its end.
    private static let yieldsInsideADelivery = 10

    @Test("a delivery starts only after every earlier delivery ends")
    func deliveriesDoNotOverlap() async {
        let steps = Recorder<String>()
        var chain = SerialAsyncChain()
        var deliveries: [Task<Void, Never>] = []

        for index in 1...Self.deliveryCount {
            deliveries.append(
                chain.enqueue {
                    steps.append("start \(index)")
                    for _ in 0..<Self.yieldsInsideADelivery {
                        await Task.yield()
                    }
                    steps.append("end \(index)")
                })
        }
        for delivery in deliveries {
            await delivery.value
        }

        let expected = (1...Self.deliveryCount).flatMap { ["start \($0)", "end \($0)"] }
        #expect(steps.values == expected)
    }

    @Test("the returned task ends when its own delivery ends")
    func theReturnedTaskIsTheDelivery() async {
        let steps = Recorder<String>()
        var chain = SerialAsyncChain()

        let delivery = chain.enqueue { steps.append("delivered") }
        await delivery.value

        #expect(steps.values == ["delivered"])
    }
}
