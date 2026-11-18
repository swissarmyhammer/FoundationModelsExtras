import FoundationModelsExtras
import Testing

/// ``SessionSlug`` makes the slug of a session name.
@Suite("SessionSlug: the slug of a session name")
struct SessionSlugTests {
    @Test("a title of words gives the words in lower case with a hyphen between them")
    func wordsBecomeAHyphenatedSlug() {
        #expect(SessionSlug.make(from: "Fix the API tests") == "fix-the-api-tests")
    }

    @Test("each run of other characters becomes one hyphen, and no hyphen is at an end")
    func runsOfOtherCharactersBecomeOneHyphen() {
        #expect(SessionSlug.make(from: "  --Hello__World!! ") == "hello-world")
    }

    @Test("a name with no letter and no digit gives an empty slug")
    func aNameWithNoLetterGivesAnEmptySlug() {
        #expect(SessionSlug.make(from: "!!!").isEmpty)
    }

    @Test("letters with accents stay in the slug")
    func lettersWithAccentsStay() {
        #expect(SessionSlug.make(from: "Café Ünïcode") == "café-ünïcode")
    }
}
