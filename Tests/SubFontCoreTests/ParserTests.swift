import Foundation
import SubFontCore

final class ParserTests: CheckCase, @unchecked Sendable {
    func testActualStylesAndOverrides() throws {
        let text = """
        [V4+ Styles]
        Format: Name, Fontname, Bold, Italic
        Style: Default,Arial,0,0
        Style: Unused,Never Used,0,0
        Style: Other,Other Font,-1,-1
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,Hello,{\\fnInline\\b1}World{\\rOther}Other{\\p1}m 0 0 l 10 10{\\p0\\r}!
        Comment: 0,0:00:00.00,0:00:01.00,Unused,,0,0,0,,Ignored
        """
        let result = try ASSParser.parse(data: Data(text.utf8))
        expectEqual(Set(result.requests), Set([
            FontRequest(name: "Arial"), FontRequest(name: "Inline", weight: 700),
            FontRequest(name: "Other Font", weight: 700, italic: true)
        ]))
        expectTrue(result.warnings.isEmpty)
    }
    func testUnicodeEncodingsAndVerticalName() throws {
        let text = "[V4+ Styles]\nFormat: Name,Fontname\nStyle: Default,@中文字体\n[Events]\nFormat: Style,Text\nDialogue: Default,你好"
        let utf8 = try ASSParser.parse(data: Data(text.utf8))
        let utf16 = try ASSParser.parse(data: Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!)
        expectEqual(utf8.requests, [FontRequest(name: "中文字体")])
        expectEqual(utf8.requests, utf16.requests)
    }
    func testDrawingAndOverriddenNamesAreNotRequired() {
        let text = "[V4+ Styles]\nFormat: Name,Fontname\nStyle: Default,Unused\n[Events]\nFormat: Style,Text\nDialogue: Default,{\\fnWrong\\fnRight\\p1}m 0 0 l 10 10{\\p0}Text"
        expectEqual(ASSParser.parse(text: text).requests, [FontRequest(name: "Right")])
    }
    func testNormalizationPreservesSignificantCharacters() {
        expectEqual(FontName.key("École"), FontName.key("E\u{301}COLE"))
        expectNotEqual(FontName.key("Font-A"), FontName.key("Font A"))
        expectNotEqual(FontName.key("字体"), FontName.key("字體"))
    }
}
