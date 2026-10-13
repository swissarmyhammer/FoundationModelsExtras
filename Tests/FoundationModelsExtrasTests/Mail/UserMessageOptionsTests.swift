import Foundation
@testable import FoundationModelsExtras
import Testing

/// ``UserMessageOptions`` holds the generation options of one user message.
@Suite("UserMessageOptions: the token limit and the mode of a user message")
struct UserMessageOptionsTests {
    @Test("the default options have no token limit and the mode reply")
    func theDefaults() {
        let options = UserMessageOptions()

        #expect(options.maxTokens == nil)
        #expect(options.mode == .reply)
    }

    @Test(
        "the options survive a JSON round trip",
        arguments: [
            UserMessageOptions(),
            UserMessageOptions(maxTokens: 512),
            UserMessageOptions(mode: .stream),
            UserMessageOptions(maxTokens: 64, mode: .stream),
        ])
    func theOptionsSurviveARoundTrip(options: UserMessageOptions) throws {
        let decoded = try JSONDecoder().decode(UserMessageOptions.self, from: JSONEncoder().encode(options))

        #expect(decoded == options)
    }

    @Test("each mode has its fixed raw value")
    func eachModeHasItsRawValue() {
        #expect(UserMessageOptions.Mode.reply.rawValue == "reply")
        #expect(UserMessageOptions.Mode.stream.rawValue == "stream")
    }
}
