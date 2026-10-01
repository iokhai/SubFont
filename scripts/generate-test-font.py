"""Generate an original, minimal font fixture (one drawn glyph, no third-party outlines).
Run: uv run --with fonttools scripts/generate-test-font.py
"""
from pathlib import Path
from copy import deepcopy
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.ttLib import TTCollection

builder = FontBuilder(1000, isTTF=True)
builder.setupGlyphOrder([".notdef", "A"])
glyphs = {}
for name in [".notdef", "A"]:
    pen = TTGlyphPen(None)
    if name == "A":
        pen.moveTo((80, 0))
        pen.lineTo((300, 700))
        pen.lineTo((520, 0))
        pen.lineTo((400, 0))
        pen.lineTo((300, 420))
        pen.lineTo((200, 0))
        pen.closePath()
    glyphs[name] = pen.glyph()
builder.setupGlyf(glyphs)
builder.setupHorizontalMetrics({".notdef": (600, 0), "A": (600, 80)})
builder.setupHorizontalHeader(ascent=800, descent=-200)
builder.setupCharacterMap({65: "A"})
builder.setupNameTable({
    "familyName": "SubFont Test Fixture",
    "styleName": "Regular",
    "uniqueFontIdentifier": "SubFont-Test-Fixture-1",
    "fullName": "SubFont Test Fixture Regular",
    "psName": "SubFontTestFixture-Regular",
    "version": "Version 1.0",
})
builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
builder.setupPost()
builder.setupMaxp()
builder.font["name"].setName("字幕字体测试", 1, 3, 1, 0x0804)
builder.font["name"].setName("字幕字體測試", 1, 3, 1, 0x0404)
builder.font["name"].setName("SubFont Unicode Alias", 1, 0, 4, 0)
output = Path(__file__).resolve().parent.parent / "Tests/SubFontCoreTests/Fixtures/SubFontTest-Regular.ttf"
builder.save(output)
second = deepcopy(builder.font)
for record in second["name"].names:
    original = record.toUnicode()
    replacement = original.replace("SubFont Test Fixture", "SubFont Second Fixture").replace(
        "SubFontTestFixture", "SubFontSecondFixture").replace("SubFont-Test-Fixture", "SubFont-Second-Fixture")
    record.string = replacement.encode(record.getEncoding())
second.save(output.with_name("SubFontTest-Second.ttf"))
collection = TTCollection()
collection.fonts = [builder.font, second]
collection.save(output.with_name("SubFontTest-Collection.ttc"))
cff = FontBuilder(1000, isTTF=False)
cff.setupGlyphOrder([".notdef", "A"])
cff.setupCharacterMap({65: "A"})
charstrings = {}
for name in [".notdef", "A"]:
    pen = T2CharStringPen(600, None)
    if name == "A":
        pen.moveTo((80, 0))
        pen.lineTo((300, 700))
        pen.lineTo((520, 0))
        pen.closePath()
    charstrings[name] = pen.getCharString()
cff.setupCFF("SubFontCFFFixture-Regular", {
    "FullName": "SubFont CFF Fixture Regular", "FamilyName": "SubFont CFF Fixture", "Weight": "Regular",
}, charstrings, {})
cff.setupHorizontalMetrics({".notdef": (600, 0), "A": (600, 80)})
cff.setupHorizontalHeader(ascent=800, descent=-200)
cff.setupNameTable({
    "familyName": "SubFont CFF Fixture", "styleName": "Regular",
    "uniqueFontIdentifier": "SubFont-CFF-Fixture-1", "fullName": "SubFont CFF Fixture Regular",
    "psName": "SubFontCFFFixture-Regular", "version": "Version 1.0",
})
cff.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
cff.setupPost()
cff.save(output.with_name("SubFontTest-CFF.otf"))
print(output)
