import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `FrontmatterDocument.split`, covering the fence
/// recognition rules from plan.md §4: a leading `---` line opens a
/// frontmatter block, a subsequent `---` line closes it, and anything that
/// does not match that shape is body text.
@Suite struct FrontmatterDocumentTests {
    @Test func splitsFrontmatterAndBodyPreservingBodyByteForByte() {
        let text = "---\ntitle: Test\n---\n# Body\ncontent\n"

        let result = FrontmatterDocument.split(text: text)

        #expect(result.frontmatter == "title: Test\n")
        #expect(result.body == "# Body\ncontent\n")
    }

    @Test func noFrontmatterReturnsNilAndWholeText() {
        let text = "# Just a heading\nsome body text\n"

        let result = FrontmatterDocument.split(text: text)

        #expect(result.frontmatter == nil)
        #expect(result.body == text)
    }

    @Test func emptyFrontmatterBlockReturnsEmptyStringFrontmatter() {
        let text = "---\n---\n"

        let result = FrontmatterDocument.split(text: text)

        #expect(result.frontmatter == "")
        #expect(result.body == "")
    }

    @Test func laterDashesInBodyAreNotTreatedAsAFence() {
        let text = "Some text\n---\nmore text\n"

        let result = FrontmatterDocument.split(text: text)

        #expect(result.frontmatter == nil)
        #expect(result.body == text)
    }

    @Test func unterminatedOpeningFenceIsTreatedAsBody() {
        let text = "---\ntitle: Test\nno closing fence here\n"

        let result = FrontmatterDocument.split(text: text)

        #expect(result.frontmatter == nil)
        #expect(result.body == text)
    }

    @Test func crlfInputIsHandled() {
        let text = "---\r\ntitle: Test\r\n---\r\n# Body\r\ncontent\r\n"

        let result = FrontmatterDocument.split(text: text)

        #expect(result.frontmatter == "title: Test\r\n")
        #expect(result.body == "# Body\r\ncontent\r\n")
    }
}
