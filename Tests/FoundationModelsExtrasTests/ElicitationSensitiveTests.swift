@testable import FoundationModelsExtras
import Foundation
import Testing
import ULID

/// Exercises the sensitive flag of an ``ElicitationRequest``: its default,
/// the two inits that set it, its wire key, and the relay that keeps it.
@Suite("Elicitation request: the sensitive flag of a question whose answer holds a secret")
struct ElicitationSensitiveTests {
    /// The form of each form request of this suite.
    private static let schema = ElicitationRequestedSchema(
        properties: ["token": .string(ElicitationStringSchema())], required: ["token"])

    /// The id of each request that a test decodes from JSON.
    private static let recordedId = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    /// The URL of each URL request of this suite.
    private static let signInAddress = "https://example.com/sign-in"

    /// A form request for a token.
    ///
    /// - Parameter sensitive: The flag of the request.
    /// - Returns: The request.
    private static func tokenRequest(sensitive: Bool) -> ElicitationRequest {
        ElicitationRequest(
            message: "Your token?", elicitationId: ULID(), requestedSchema: schema, sensitive: sensitive)
    }

    /// The JSON object of `request`.
    ///
    /// - Parameter request: The request.
    /// - Returns: The object.
    /// - Throws: The error of the encode, or a failed expectation when the
    ///   JSON is not an object.
    private static func object(of request: ElicitationRequest) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        return try #require(object as? [String: Any])
    }

    @Test("a request made with no sensitive argument is not sensitive")
    func theDefaultIsNotSensitive() {
        let request = ElicitationRequest(message: "Your name?", elicitationId: ULID(), requestedSchema: Self.schema)

        #expect(request.sensitive == false)
    }

    @Test("the form init sets the sensitive flag")
    func theFormInitTakesTheFlag() {
        #expect(Self.tokenRequest(sensitive: true).sensitive)
    }

    @Test("the URL init sets the sensitive flag")
    func theURLInitTakesTheFlag() throws {
        let request = try ElicitationRequest(
            message: "Sign in", elicitationId: ULID(), url: #require(URL(string: Self.signInAddress)),
            sensitive: true)

        #expect(request.sensitive)
    }

    @Test("a request that is not sensitive encodes no sensitive key")
    func aPlainRequestHasNoSensitiveKey() throws {
        let object = try Self.object(of: Self.tokenRequest(sensitive: false))

        #expect(object["sensitive"] == nil)
    }

    @Test("a sensitive request encodes the key sensitive with the value true")
    func aSensitiveRequestHasTheKey() throws {
        let object = try Self.object(of: Self.tokenRequest(sensitive: true))

        #expect(object["sensitive"] as? Bool == true)
    }

    @Test("a recorded request with no sensitive key decodes as not sensitive")
    func aMissingKeyDecodesAsNotSensitive() throws {
        let json = """
            {"mode": "url", "message": "Sign in", "elicitationId": "\(Self.recordedId)",
             "url": "\(Self.signInAddress)"}
            """

        let request = try JSONDecoder().decode(ElicitationRequest.self, from: Data(json.utf8))

        #expect(request.sensitive == false)
    }

    @Test("a sensitive request encodes and decodes to a sensitive request")
    func aSensitiveRequestRoundTrips() throws {
        let request = Self.tokenRequest(sensitive: true)

        let decoded = try JSONDecoder().decode(ElicitationRequest.self, from: JSONEncoder().encode(request))

        #expect(decoded.sensitive)
    }

    @Test("a relay of a sensitive request keeps the flag")
    func aRelayKeepsTheFlag() {
        let relayed = Self.tokenRequest(sensitive: true).relayed(by: "reviewer", askedBy: "github")

        #expect(relayed.sensitive)
    }
}
