import Foundation

/// Reads metadata tables only. It never registers a font or reads glyph outlines.
public enum FontMetadataReader {
    public static let version = 1
    public static let extensions: Set<String> = ["ttf", "otf", "ttc", "otc"]

    public static func read(_ url: URL) throws -> [FontFace] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        func bytes(_ offset: UInt64, _ count: Int) throws -> Data {
            guard count >= 0, count <= 16 * 1024 * 1024, offset <= length,
                  UInt64(count) <= length - offset else { throw corrupt() }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw corrupt() }
            return data
        }
        let header = try bytes(0, 12)
        let offsets: [UInt64]
        if header.u32(0) == 0x74746366 {
            let count = Int(header.u32(8))
            guard count > 0, count <= 4096 else { throw corrupt() }
            let table = try bytes(12, count * 4)
            offsets = (0..<count).map { UInt64(table.u32($0 * 4)) }
        } else {
            offsets = [0]
        }
        return try offsets.enumerated().map { index, offset in
            let head = try bytes(offset, 12)
            guard [0x00010000, 0x4F54544F, 0x74727565].contains(head.u32(0)) else { throw corrupt() }
            let count = Int(head.u16(4))
            guard count > 0, count <= 4096 else { throw corrupt() }
            let directory = try bytes(offset + 12, count * 16)
            var tables: [UInt32: (UInt64, Int)] = [:]
            for i in 0..<count {
                let p = i * 16
                tables[directory.u32(p)] = (UInt64(directory.u32(p + 8)), Int(directory.u32(p + 12)))
            }
            guard let nameTable = tables[0x6E616D65] else { throw corrupt("字体没有名称表") }
            let data = try bytes(nameTable.0, nameTable.1)
            let names = Set(try decodeNames(data))
            func best(_ kinds: [Int]) -> String {
                for kind in kinds {
                    if let value = names.filter({ $0.kind == kind }).sorted(by: {
                        let l = $0.language == 0x409 ? 0 : 1, r = $1.language == 0x409 ? 0 : 1
                        return l == r ? $0.name < $1.name : l < r
                    }).first { return value.name }
                }
                return ""
            }
            var weight = 400, italic = false, revision: Int64 = 0
            if let table = tables[0x4F532F32], table.1 >= 6 {
                let os2 = try bytes(table.0, min(table.1, 64))
                weight = max(1, min(1000, Int(os2.u16(4))))
                if os2.count >= 64 { italic = os2.u16(62) & 1 != 0 }
            }
            if let table = tables[0x68656164], table.1 >= 46 {
                let fontHead = try bytes(table.0, 46)
                revision = Int64(fontHead.u32(4))
                italic = italic || fontHead.u16(44) & 2 != 0
            }
            let aliases = names.filter { [1, 4, 6, 16, 18, 21].contains($0.kind) }
                .sorted { ($0.kind, $0.language, $0.name) < ($1.kind, $1.language, $1.name) }
            guard !aliases.isEmpty else { throw corrupt("未找到可识别的字体名称") }
            return FontFace(index: index, postScriptName: best([6]), family: best([16, 1]),
                            weight: weight, italic: italic, revision: revision, names: aliases)
        }
    }

    static func decodeNames(_ data: Data) throws -> [FontAlias] {
    guard data.count >= 6, data.u16(0) <= 1 else { throw corrupt("不支持的字体名称表") }
    let records = Int(data.u16(2)), storage = Int(data.u16(4))
    guard 6 + records * 12 <= data.count, storage <= data.count else { throw corrupt() }
    var names = Set<FontAlias>()
    for n in 0..<records {
        let p = 6 + n * 12
        let platform = data.u16(p), encoding = data.u16(p + 2)
        let language = Int(data.u16(p + 4)), kind = Int(data.u16(p + 6))
        guard [1, 2, 4, 6, 16, 17, 18, 21, 22].contains(kind) else { continue }
        let start = storage + Int(data.u16(p + 10)), size = Int(data.u16(p + 8))
        guard start <= data.count, size <= data.count - start else { throw corrupt() }
        let raw = data.subdata(in: start..<(start + size))
        let string: String?
        if platform == 0 || (platform == 3 && [0, 1, 10].contains(encoding)) {
            string = size % 2 == 0 ? String(data: raw, encoding: .utf16BigEndian) : nil
        } else if platform == 1 && encoding == 0 {
            string = String(data: raw, encoding: .macOSRoman)
        } else { string = nil }
        if let string, !string.isEmpty, !string.contains("\0") {
            names.insert(FontAlias(name: string, kind: kind, language: language))
        }
    }
        return Array(names)
    }

    private static func corrupt(_ message: String = "字体文件损坏或格式不受支持") -> SubFontError { .message(message) }
}

private extension Data {
    func u16(_ p: Int) -> UInt16 { UInt16(self[p]) << 8 | UInt16(self[p + 1]) }
    func u32(_ p: Int) -> UInt32 {
        UInt32(self[p]) << 24 | UInt32(self[p + 1]) << 16 | UInt32(self[p + 2]) << 8 | UInt32(self[p + 3])
    }
}
