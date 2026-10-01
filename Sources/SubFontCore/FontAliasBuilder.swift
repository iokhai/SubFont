import Foundation

/// Creates a standalone face with a native family alias. Glyph/layout tables are preserved.
/// Used only for selected fonts whose localized Windows names Core Text cannot resolve.
enum FontAliasBuilder {
    private struct Table { let tag: UInt32; var bytes: Data }
    private struct NameRecord {
        let platform: UInt16; let encoding: UInt16; let language: UInt16; let kind: UInt16; let text: Data
    }
    static func make(candidate: FontCandidate, alias: String) throws -> Data {
        let source = try Data(contentsOf: candidate.url, options: .mappedIfSafe)
        guard source.count >= 12 else { throw invalid() }
        var offset = 0
        if source.read32(0) == 0x74746366 {
            let count = Int(source.read32(8))
            guard candidate.faceIndex >= 0, candidate.faceIndex < count,
                  12 + count * 4 <= source.count else { throw invalid() }
            offset = Int(source.read32(12 + candidate.faceIndex * 4))
        }
        guard offset <= source.count - 12 else { throw invalid() }
        let flavor = source.read32(offset), count = Int(source.read16(offset + 4))
        guard count <= 4096, offset + 12 + count * 16 <= source.count else { throw invalid() }
        var tables: [Table] = []
        for i in 0..<count {
            let p = offset + 12 + i * 16, tag = source.read32(p)
            let start = Int(source.read32(p + 8)), length = Int(source.read32(p + 12))
            guard start <= source.count, length <= source.count - start else { throw invalid() }
            if tag != 0x44534947 { // A signature cannot apply to renamed metadata.
                tables.append(Table(tag: tag, bytes: source.subdata(in: start..<(start + length))))
            }
        }
        var postScript = "SubFontAlias" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        if let cff = tables.firstIndex(where: { $0.tag == 0x43464620 }) {
            var bytes = tables[cff].bytes
            guard bytes.count >= 4 else { throw invalid() }
            let h = Int(bytes[2])
            guard h <= bytes.count - 3, bytes.read16(h) == 1 else { throw invalid("不支持此 CFF 字体的兼容名称") }
            let size = Int(bytes[h + 2])
            guard (1...4).contains(size), h + 3 + 2 * size <= bytes.count else { throw invalid() }
            func indexOffset(_ position: Int) -> Int {
                (0..<size).reduce(0) { ($0 << 8) | Int(bytes[position + $1]) }
            }
            let first = indexOffset(h + 3), last = indexOffset(h + 3 + size)
            let start = h + 3 + 2 * size + first - 1, length = last - first
            guard first >= 1, (1...63).contains(length), start >= 0,
                  start <= bytes.count, length <= bytes.count - start else { throw invalid() }
            // Keep the CFF Name INDEX byte length unchanged so all internal offsets stay valid.
            let initial = String("ABCDEFGHIJKLMNOPQRSTUVWXYZ".randomElement()!)
            let random = UUID().uuidString.replacingOccurrences(of: "-", with: "") +
                         UUID().uuidString.replacingOccurrences(of: "-", with: "")
            postScript = String((initial + random).prefix(length))
            bytes.replaceSubrange(start..<(start + length), with: postScript.utf8)
            tables[cff].bytes = bytes
        }
        guard let name = tables.firstIndex(where: { $0.tag == 0x6E616D65 }) else { throw invalid() }
        let style = candidate.weight >= 600 ? (candidate.italic ? "Bold Italic" : "Bold") :
                    (candidate.italic ? "Italic" : "Regular")
        tables[name].bytes = try renamedTable(tables[name].bytes, family: alias, style: style, postScript: postScript)
        if let head = tables.firstIndex(where: { $0.tag == 0x68656164 }) {
            guard tables[head].bytes.count >= 12 else { throw invalid() }
            tables[head].bytes.replaceSubrange(8..<12, with: [0, 0, 0, 0])
        } else { throw invalid() }
        tables.sort { $0.tag < $1.tag }
        let n = tables.count, power = 1 << Int(log2(Double(n)))
        var output = Data()
        output.append32(flavor); output.append16(n); output.append16(power * 16)
        output.append16(Int(log2(Double(power)))); output.append16(n * 16 - power * 16)
        var body = Data(), headOffset = 0
        for table in tables {
            let start = 12 + n * 16 + body.count
            guard let start32 = UInt32(exactly: start), let length32 = UInt32(exactly: table.bytes.count) else { throw invalid() }
            output.append32(table.tag); output.append32(checksum(table.bytes))
            output.append32(start32); output.append32(length32)
            if table.tag == 0x68656164 { headOffset = start }
            body.append(table.bytes)
            while body.count % 4 != 0 { body.append(0) }
        }
        output.append(body)
        var adjustment = Data()
        adjustment.append32(0xB1B0AFBA &- checksum(output))
        output.replaceSubrange((headOffset + 8)..<(headOffset + 12), with: adjustment)
        return output
    }

    private static func renamedTable(_ data: Data, family: String, style: String, postScript: String) throws -> Data {
        guard data.count >= 6, data.read16(0) <= 1 else { throw invalid() }
        let format = Int(data.read16(0)), count = Int(data.read16(2)), storage = Int(data.read16(4))
        guard 6 + count * 12 <= data.count, storage <= data.count else { throw invalid() }
        func text(_ offset: Int, _ length: Int) throws -> Data {
            let start = storage + offset
            guard start <= data.count, length <= data.count - start else { throw invalid() }
            return data.subdata(in: start..<(start + length))
        }
        let replaced: Set<UInt16> = [1, 2, 3, 4, 6, 16, 17, 18, 21, 22, 25]
        var records: [NameRecord] = []
        for i in 0..<count {
            let p = 6 + 12 * i, kind = data.read16(p + 6)
            if !replaced.contains(kind) {
                records.append(NameRecord(platform: data.read16(p), encoding: data.read16(p + 2),
                    language: data.read16(p + 4), kind: kind,
                    text: try text(Int(data.read16(p + 10)), Int(data.read16(p + 8)))))
            }
        }
        var languages: [Data] = []
        if format == 1 {
            let p = 6 + count * 12
            guard p + 2 <= data.count else { throw invalid() }
            let languageCount = Int(data.read16(p))
            guard p + 2 + 4 * languageCount <= data.count else { throw invalid() }
            for i in 0..<languageCount {
                languages.append(try text(Int(data.read16(p + 4 + i * 4)), Int(data.read16(p + 2 + i * 4))))
            }
        }
        let full = style == "Regular" ? family : family + " " + style
        let values: [(UInt16, String)] = [(1,family),(2,style),(3,postScript),(4,full),(6,postScript),
                                          (16,family),(17,style),(18,full),(21,family),(22,style),(25,postScript)]
        for (kind, value) in values {
            let bytes = value.data(using: .utf16BigEndian)!
            records.append(NameRecord(platform: 0, encoding: 4, language: 0, kind: kind, text: bytes))
            for language: UInt16 in [0x409, 0x804, 0x404] {
                records.append(NameRecord(platform: 3, encoding: 1, language: language, kind: kind, text: bytes))
            }
            if let mac = value.data(using: .macOSRoman) {
                records.append(NameRecord(platform: 1, encoding: 0, language: 0, kind: kind, text: mac))
            }
        }
        records.sort { ($0.platform,$0.encoding,$0.language,$0.kind) < ($1.platform,$1.encoding,$1.language,$1.kind) }
        let start = 6 + records.count * 12 + (format == 1 ? 2 + languages.count * 4 : 0)
        guard start <= 65535, records.count <= 65535 else { throw invalid("字体名称表过大") }
        var output = Data(), strings = Data()
        output.append16(format); output.append16(records.count); output.append16(start)
        func appendString(_ bytes: Data) throws -> (Int, Int) {
            guard strings.count <= 65535, bytes.count <= 65535 else { throw invalid("字体名称表过大") }
            let offset = strings.count; strings.append(bytes)
            return (bytes.count, offset)
        }
        for record in records {
            let (length, offset) = try appendString(record.text)
            output.append16(Int(record.platform)); output.append16(Int(record.encoding))
            output.append16(Int(record.language)); output.append16(Int(record.kind))
            output.append16(length); output.append16(offset)
        }
        if format == 1 {
            output.append16(languages.count)
            for language in languages {
                let (length, offset) = try appendString(language)
                output.append16(length); output.append16(offset)
            }
        }
        output.append(strings)
        return output
    }
    private static func checksum(_ bytes: Data) -> UInt32 {
        var sum: UInt32 = 0
        for start in stride(from: 0, to: bytes.count, by: 4) {
            var word: UInt32 = 0
            for i in 0..<4 { word = word << 8 | (start + i < bytes.count ? UInt32(bytes[start + i]) : 0) }
            sum &+= word
        }
        return sum
    }
    private static func invalid(_ message: String = "无法为此字体创建兼容名称") -> SubFontError { .message(message) }
}

private extension Data {
    func read16(_ p: Int) -> UInt16 { UInt16(self[p]) << 8 | UInt16(self[p + 1]) }
    func read32(_ p: Int) -> UInt32 { UInt32(read16(p)) << 16 | UInt32(read16(p + 2)) }
    mutating func append16(_ v: Int) { append(UInt8((v >> 8) & 255)); append(UInt8(v & 255)) }
    mutating func append32(_ v: UInt32) { append16(Int(v >> 16)); append16(Int(v & 65535)) }
}
