import Foundation
import CZlib

/// Font analysis only; timestamps and audio/video codecs do not affect this reader.
/// Packet layout: https://www.matroska.org/technical/subtitles.html#ssaass-subtitles
struct MatroskaSubtitles {
    private struct Element {
        let id: UInt64
        let start: UInt64
        let end: UInt64
        let unknown: Bool
        var range: Range<UInt64> { start..<end }
    }
    private struct Encoding {
        let order: UInt64
        let scope: UInt64
        let algorithm: UInt64
        let settings: Data
    }
    private final class Track {
        let number: UInt64
        let label: String
        let codec: String
        var encodings: [Encoding] = []
        var header = Data()
        var events = ""
        var requests: [String: FontRequest] = [:]
        var warnings = Set<String>()
        var supported = false
        var failed = false
        init(number: UInt64, label: String, codec: String) {
            self.number = number; self.label = label; self.codec = codec
        }
        func flush() throws {
            guard !events.isEmpty else { return }
            guard var text = String(data: header, encoding: .utf8) else { throw MediaBytes.invalid }
            if let range = text.range(of: "[Events]", options: .caseInsensitive) { text = String(text[..<range.lowerBound]) }
            text += "\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" + events
            let result = ASSParser.parse(text: text)
            for request in result.requests { requests[request.id] = request }
            warnings.formUnion(result.warnings)
            events = ""
        }
        func decode(_ input: Data, scope: UInt64) throws -> Data {
            var data = input
            for encoding in encodings where encoding.scope & scope != 0 {
                if encoding.algorithm == 3 {
                    guard encoding.settings.count + data.count <= 4 * 1024 * 1024 else { throw MediaBytes.invalid }
                    data = encoding.settings + data
                } else {
                    var capacity = max(4096, min(4 * 1024 * 1024, data.count * 3))
                    while true {
                        try Task.checkCancellation()
                        var output = [UInt8](repeating: 0, count: capacity)
                        var length = uLongf(capacity)
                        let result = data.withUnsafeBytes { source in
                            output.withUnsafeMutableBufferPointer { destination in
                                uncompress(destination.baseAddress, &length, source.bindMemory(to: Bytef.self).baseAddress, uLong(data.count))
                            }
                        }
                        if result == Z_OK { data = Data(output.prefix(Int(length))); break }
                        guard result == Z_BUF_ERROR, capacity < 4 * 1024 * 1024 else {
                            throw SubFontError.message("字幕压缩数据无效或解压后超过 4 MiB")
                        }
                        capacity = min(capacity * 2, 4 * 1024 * 1024)
                    }
                }
            }
            return data
        }
    }

    private let file: MediaFileReader
    private let topLevel: Set<UInt64> = [0x114D9B74, 0x1549A966, 0x1654AE6B, 0x1F43B675,
                                        0x1C53BB6B, 0x1941A469, 0x1043A770, 0x1254C367]
    init(file: MediaFileReader) { self.file = file }

    func read() throws -> MediaContents {
        let ebml = try element(at: 0, limit: file.size)
        guard ebml.id == 0x1A45DFA3, !ebml.unknown else { throw MediaBytes.invalid }
        let header = try children(ebml)
        guard let type = header.first(where: { $0.id == 0x4282 }),
              ["matroska", "webm"].contains(try string(type)) else {
            throw SubFontError.message("不是 Matroska 视频文件")
        }
        var cursor = ebml.end
        var segment: Element?
        while cursor < file.size {
            let item = try element(at: cursor, limit: file.size)
            if item.id == 0x18538067 { segment = item; break }
            guard !item.unknown else { throw MediaBytes.invalid }
            cursor = item.end
        }
        guard let segment else { throw MediaBytes.invalid }
        var tracks: [UInt64: Track] = [:], clusters: [Element] = [], attachments: [EmbeddedAttachment] = []
        var headerBytes = 0
        cursor = segment.start
        while cursor < segment.end {
            let item = try element(at: cursor, limit: segment.end)
            switch item.id {
            case 0x1654AE6B:
                for entry in try children(item) where entry.id == 0xAE {
                    if let track = try track(entry) {
                        guard tracks.count < 256, tracks[track.number] == nil else { throw MediaBytes.invalid }
                        headerBytes += track.header.count + track.encodings.reduce(0) { $0 + $1.settings.count }
                        guard headerBytes <= 16 * 1024 * 1024 else { throw SubFontError.message("字幕轨元数据总量超过 16 MiB") }
                        tracks[track.number] = track
                    }
                }
            case 0x1941A469:
                attachments += try attachedFiles(item)
                guard attachments.count <= 256 else { throw SubFontError.message("视频中的字体附件过多") }
            case 0x1F43B675:
                let end = item.unknown ? try clusterEnd(item) : item.end
                clusters.append(Element(id: item.id, start: item.start, end: end, unknown: false))
                guard clusters.count <= 100_000 else { throw SubFontError.message("视频中的分段过多") }
                cursor = end
                continue
            default:
                guard !item.unknown else { throw MediaBytes.invalid }
            }
            cursor = item.end
        }
        var totalText = 0
        if tracks.values.contains(where: { $0.supported }) {
            for cluster in clusters {
                var offset = cluster.start
                while offset < cluster.end {
                    let item = try element(at: offset, limit: cluster.end)
                    guard !item.unknown else { throw MediaBytes.invalid }
                    if item.id == 0xA3 {
                        try block(item, state: nil, tracks: tracks, total: &totalText)
                    } else if item.id == 0xA0 {
                        let entries = try children(item)
                        let state = entries.first { $0.id == 0xA4 }
                        for payload in entries where payload.id == 0xA1 {
                            try block(payload, state: state, tracks: tracks, total: &totalText)
                        }
                    }
                    offset = item.end
                }
            }
        }
        var result = MediaContents()
        var requests: [String: FontRequest] = [:]
        for track in tracks.values.sorted(by: { $0.number < $1.number }) {
            if track.supported {
                do { try track.flush() }
                catch { track.warnings.insert(error.localizedDescription) }
                for request in track.requests.values { requests[request.id] = request }
                if track.requests.isEmpty && track.warnings.isEmpty {
                    track.warnings.insert("没有可解析的 ASS/SSA 对白")
                }
            }
            result.warnings += track.warnings.sorted().map { "\(track.label)：\($0)" }
        }
        if tracks.isEmpty { result.warnings.append("视频没有内嵌字幕轨") }
        result.requests = requests.values.sorted { $0.id < $1.id }
        result.attachments = attachments
        result.bytesRead = file.bytesRead
        return result
    }

    private func element(at offset: UInt64, limit: UInt64) throws -> Element {
        try file.countedElement()
        guard offset < limit, limit <= file.size else { throw MediaBytes.invalid }
        var bytes = MediaBytes(try file.read(offset, Int(min(12, limit - offset))))
        let id = try bytes.vint(id: true).value
        let size = try bytes.vint()
        let start = offset + UInt64(bytes.position)
        guard start <= limit, size.unknown || size.value <= limit - start else { throw MediaBytes.invalid }
        return Element(id: id, start: start, end: size.unknown ? limit : start + size.value, unknown: size.unknown)
    }
    private func children(_ parent: Element) throws -> [Element] {
        guard !parent.unknown else { throw MediaBytes.invalid }
        var result: [Element] = [], cursor = parent.start
        while cursor < parent.end {
            let item = try element(at: cursor, limit: parent.end)
            guard !item.unknown, result.count < 10_000 else { throw MediaBytes.invalid }
            result.append(item); cursor = item.end
        }
        return result
    }
    private func data(_ item: Element, maximum: UInt64 = 4 * 1024 * 1024) throws -> Data {
        guard item.end - item.start <= maximum else { throw SubFontError.message("字幕元数据超过读取限制") }
        return try file.read(item.start, Int(item.end - item.start))
    }
    private func string(_ item: Element) throws -> String {
        guard let text = String(data: try data(item, maximum: 65536), encoding: .utf8) else { throw MediaBytes.invalid }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
    private func integer(_ item: Element) throws -> UInt64 {
        let value = try data(item, maximum: 8)
        if value.isEmpty { return 0 }
        var bytes = MediaBytes(value)
        return try bytes.uint(value.count)
    }
    private func number(_ entries: [Element], _ id: UInt64, default fallback: UInt64 = 0) throws -> UInt64 {
        try entries.first(where: { $0.id == id }).map(integer) ?? fallback
    }
    private func clusterEnd(_ cluster: Element) throws -> UInt64 {
        var cursor = cluster.start
        while cursor < cluster.end {
            let item = try element(at: cursor, limit: cluster.end)
            if topLevel.contains(item.id) { return cursor }
            guard !item.unknown else { throw MediaBytes.invalid }
            cursor = item.end
        }
        return cursor
    }
    private func track(_ item: Element) throws -> Track? {
        let fields = try children(item)
        guard try number(fields, 0x83) == 0x11 else { return nil }
        let number = try number(fields, 0xD7)
        guard number > 0, let codecField = fields.first(where: { $0.id == 0x86 }) else { throw MediaBytes.invalid }
        let codec = try string(codecField)
        let name = try fields.first(where: { $0.id == 0x536E }).map(string) ?? ""
        let track = Track(number: number, label: name.isEmpty ? "字幕轨 \(number)" : "字幕轨 \(number)（\(name)）", codec: codec)
        guard ["S_TEXT/ASS", "S_TEXT/SSA", "S_ASS", "S_SSA"].contains(codec) else {
            if ["S_HDMV/PGS", "S_VOBSUB", "S_DVBSUB", "S_IMAGE/BMP"].contains(codec) {
                track.warnings.insert("位图字幕无需加载字体")
            } else if ["S_TEXT/UTF8", "S_TEXT/ASCII"].contains(codec) {
                track.warnings.insert("纯文本字幕未声明字体")
            } else { track.warnings.insert("暂不支持 \(codec) 字幕") }
            return track
        }
        do {
            if let encodings = fields.first(where: { $0.id == 0x6D80 }) {
                for entry in try children(encodings) where entry.id == 0x6240 {
                    let values = try children(entry)
                    let scope = try self.number(values, 0x5032, default: 1)
                    guard try self.number(values, 0x5033) == 0, (1...3).contains(scope),
                          let compression = values.first(where: { $0.id == 0x5034 }) else {
                        throw SubFontError.message("不支持此字幕轨的加密或编码方式")
                    }
                    let settings = try children(compression)
                    let algorithm = try self.number(settings, 0x4254)
                    guard [0, 3].contains(algorithm), track.encodings.count < 8 else {
                        throw SubFontError.message("不支持此字幕轨的压缩方式")
                    }
                    track.encodings.append(Encoding(order: try self.number(values, 0x5031), scope: scope,
                        algorithm: algorithm, settings: try settings.first(where: { $0.id == 0x4255 }).map { try data($0) } ?? Data()))
                }
                guard Set(track.encodings.map(\.order)).count == track.encodings.count else { throw MediaBytes.invalid }
                track.encodings.sort { $0.order > $1.order }
            }
            guard let header = fields.first(where: { $0.id == 0x63A2 }) else { throw MediaBytes.invalid }
            track.header = try track.decode(data(header), scope: 2)
            track.supported = true
        } catch is CancellationError { throw CancellationError() }
        catch { track.warnings.insert(error.localizedDescription) }
        return track
    }
    private func block(_ item: Element, state: Element?, tracks: [UInt64: Track], total: inout Int) throws {
        var prefix = MediaBytes(try file.read(item.start, Int(min(12, item.end - item.start))))
        let number = try prefix.vint().value
        guard let track = tracks[number], track.supported, !track.failed else { return }
        do {
            if let state {
                try track.flush()
                track.header = try track.decode(data(state), scope: 2)
            }
            let payload = try data(item)
            let packets = try frames(payload)
            for packet in packets {
                let decoded = try track.decode(packet, scope: 1)
                total += decoded.count + 48 // Include the synthesized Dialogue prefix in the budget.
                guard total <= 64 * 1024 * 1024 else { throw SubFontError.message("内嵌字幕总量超过 64 MiB") }
                guard let text = String(data: decoded, encoding: .utf8), !text.contains("\n"), !text.contains("\r") else {
                    throw MediaBytes.invalid
                }
                let fields = text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { throw MediaBytes.invalid }
                // ReadOrder and timestamps are irrelevant to font analysis; preserve all style/text fields.
                track.events += "Dialogue: \(fields[1]),0:00:00.00,0:00:01.00," + fields.dropFirst(2).joined(separator: ",") + "\n"
            }
        } catch is CancellationError { throw CancellationError() }
        catch { track.failed = true; track.warnings.insert("解析不完整：\(error.localizedDescription)") }
    }
    private func frames(_ data: Data) throws -> [Data] {
        var bytes = MediaBytes(data)
        _ = try bytes.vint()
        _ = try bytes.uint(2)
        let flags = try bytes.uint(1) & 6
        if flags == 0 { return [try bytes.data(bytes.remaining)] }
        let count = Int(try bytes.uint(1)) + 1
        guard count > 1 else { throw MediaBytes.invalid }
        var sizes: [Int] = []
        if flags == 4 {
            guard bytes.remaining % count == 0 else { throw MediaBytes.invalid }
            sizes = Array(repeating: bytes.remaining / count, count: count)
        } else {
            for i in 0..<count - 1 {
                var size = 0
                if flags == 2 {
                    var part: UInt64
                    repeat { part = try bytes.uint(1); size += Int(part) } while part == 255
                } else {
                    let value = try bytes.vint()
                    if i == 0 { size = Int(value.value) }
                    else { size = sizes[i - 1] + Int(value.value) - Int((UInt64(1) << (7 * value.width - 1)) - 1) }
                }
                guard size >= 0, size <= data.count else { throw MediaBytes.invalid }
                sizes.append(size)
            }
            let last = bytes.remaining - sizes.reduce(0, +)
            guard last >= 0 else { throw MediaBytes.invalid }
            sizes.append(last)
        }
        return try sizes.map { try bytes.data($0) }
    }
    private func attachedFiles(_ parent: Element) throws -> [EmbeddedAttachment] {
        var result: [EmbeddedAttachment] = []
        for item in try children(parent) where item.id == 0x61A7 {
            let fields = try children(item)
            guard let nameField = fields.first(where: { $0.id == 0x466E }),
                  let payload = fields.first(where: { $0.id == 0x465C }) else { continue }
            let name = try string(nameField)
            let ext = (name as NSString).pathExtension.lowercased()
            let mime = try fields.first(where: { $0.id == 0x4660 }).map(string) ?? ""
            let known: [String: String] = ["font/ttf": "ttf", "application/x-truetype-font": "ttf",
                "application/x-font-ttf": "ttf", "font/otf": "otf", "application/vnd.ms-opentype": "otf",
                "application/x-font-opentype": "otf", "font/collection": "ttc"]
            if FontMetadataReader.extensions.contains(ext) || known[mime] != nil {
                result.append(EmbeddedAttachment(name: name, fileExtension: FontMetadataReader.extensions.contains(ext) ? ext : known[mime]!, range: payload.range))
            }
        }
        return result
    }
}
