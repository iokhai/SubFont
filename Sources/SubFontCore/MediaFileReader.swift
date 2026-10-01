import Foundation

/// Bounded, seek-based reads: video/audio payloads are never decoded or buffered.
final class MediaFileReader {
    let size: UInt64
    private let handle: FileHandle
    private(set) var bytesRead = 0
    private var elements = 0
    init(_ url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }
    deinit { try? handle.close() }
    func read(_ offset: UInt64, _ count: Int) throws -> Data {
        try Task.checkCancellation()
        guard count >= 0, count <= 64 * 1024 * 1024, offset <= size, UInt64(count) <= size - offset else {
            throw SubFontError.message("视频中的数据长度无效或超过限制")
        }
        if count == 0 { return Data() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw SubFontError.message("视频文件不完整，无法读取字幕")
        }
        bytesRead += count
        return data
    }
    func countedElement() throws {
        try Task.checkCancellation()
        elements += 1
        guard elements <= 5_000_000 else { throw SubFontError.message("视频包含过多数据块") }
    }
    func copy(_ range: Range<UInt64>, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw SubFontError.message("无法创建临时字体文件")
        }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var offset = range.lowerBound
        while offset < range.upperBound {
            let count = Int(min(64 * 1024, range.upperBound - offset))
            try output.write(contentsOf: read(offset, count))
            offset += UInt64(count)
        }
    }
}

struct MediaBytes {
    let bytes: [UInt8]
    var position = 0
    init(_ data: Data) { bytes = Array(data) }
    var remaining: Int { bytes.count - position }
    mutating func uint(_ width: Int) throws -> UInt64 {
        guard (1...8).contains(width), width <= remaining else { throw Self.invalid }
        var value: UInt64 = 0
        for _ in 0..<width { value = value << 8 | UInt64(bytes[position]); position += 1 }
        return value
    }
    mutating func data(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw Self.invalid }
        defer { position += count }
        return Data(bytes[position..<position + count])
    }
    mutating func vint(id: Bool = false) throws -> (value: UInt64, width: Int, unknown: Bool) {
        guard remaining > 0, bytes[position] != 0 else { throw Self.invalid }
        let width = bytes[position].leadingZeroBitCount + 1
        guard width <= (id ? 4 : 8), width <= remaining else { throw Self.invalid }
        let raw = try uint(width)
        let mask = (UInt64(1) << (7 * width)) - 1
        return (id ? raw : raw & mask, width, raw & mask == mask)
    }
    static var invalid: SubFontError { .message("视频中的字幕结构无效或已损坏") }
}

struct EmbeddedAttachment: Sendable {
    let name: String
    let fileExtension: String
    let range: Range<UInt64>
}
struct MediaContents: Sendable {
    var requests: [FontRequest] = []
    var warnings: [String] = []
    var attachments: [EmbeddedAttachment] = []
    var bytesRead = 0
}
