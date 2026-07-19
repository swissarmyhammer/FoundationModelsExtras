import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `TemplateContext` / `TemplateValue`: set/overwrite
/// semantics on the public surface, and a round-trip of nested array/dict
/// values through the internal Stencil export (plan.md §4).
@Suite struct TemplateContextTests {
    @Test func setStoresAStringValue() {
        var context = TemplateContext()
        context.set("name", .string("world"))

        let exported = context.stencilDictionary()

        #expect(exported["name"] as? String == "world")
    }

    @Test func settingTheSameKeyTwiceOverwritesTheValue() {
        var context = TemplateContext()
        context.set("name", .string("first"))
        context.set("name", .string("second"))

        let exported = context.stencilDictionary()

        #expect(exported["name"] as? String == "second")
    }

    @Test func numberAndBoolValuesRoundTripThroughExport() {
        var context = TemplateContext()
        context.set("count", .number(42))
        context.set("enabled", .bool(true))

        let exported = context.stencilDictionary()

        #expect(exported["count"] as? Double == 42)
        #expect(exported["enabled"] as? Bool == true)
    }

    @Test func nestedArrayAndDictValuesRoundTripThroughExport() {
        var context = TemplateContext()
        context.set("tags", .array([.string("a"), .number(2), .bool(true)]))
        context.set(
            "meta",
            .dict([
                "count": .number(3),
                "nested": .dict(["flag": .bool(false)]),
            ]))

        let exported = context.stencilDictionary()

        let tags = exported["tags"] as? [Any]
        #expect(tags?.count == 3)
        #expect(tags?[0] as? String == "a")
        #expect(tags?[1] as? Double == 2)
        #expect(tags?[2] as? Bool == true)

        let meta = exported["meta"] as? [String: Any]
        #expect(meta?["count"] as? Double == 3)
        let nested = meta?["nested"] as? [String: Any]
        #expect(nested?["flag"] as? Bool == false)
    }
}
