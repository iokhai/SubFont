import Foundation
import CoreFoundation

public struct SubtitleAnalysis: Sendable {
    public let requests: [FontRequest]
    public let warnings: [String]
}

public enum ASSParser {
    private struct Style {
        var name: String
        var weight: Int = 400
        var italic = false
    }

    public static func read(_ url: URL) throws -> SubtitleAnalysis {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw SubFontError.message("字幕超过 64 MiB：\(url.lastPathComponent)") }
        return try parse(data: Data(contentsOf: url))
    }

    public static func parse(data: Data) throws -> SubtitleAnalysis {
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xFE, 0xFF]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else {
            let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
            text = String(data: bytes, encoding: .utf8)
        }
        guard let text else {
            throw SubFontError.message("字幕编码无法识别，请将字幕保存为 UTF-8 或带 BOM 的 UTF-16。")
        }
        return parse(text: text)
    }

    public static func parse(text: String) -> SubtitleAnalysis {
        var section = "", styleFormat = ["name", "fontname", "fontsize", "primarycolour", "secondarycolour",
                                         "outlinecolour", "backcolour", "bold", "italic"]
        var eventFormat = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var styles: [String: Style] = [:]
        var events: [(String, String)] = []
        var warnings = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix(";") else { continue }
            if line.hasPrefix("[") {
                section = line.lowercased()
                if section == "[v4 styles]" {
                    styleFormat = ["name", "fontname", "fontsize", "primarycolour", "secondarycolour",
                                   "tertiarycolour", "backcolour", "bold", "italic"]
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let tag = line[..<colon].lowercased()
            let content = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if section == "[v4+ styles]" || section == "[v4 styles]" {
                if tag == "format" { styleFormat = fields(content) }
                else if tag == "style" {
                    let values = content.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    let row = dictionary(styleFormat, values)
                    if let name = row["name"], let font = row["fontname"], !font.isEmpty {
                        styles[name] = Style(name: font, weight: (Int(row["bold"] ?? "") ?? 0) != 0 ? 700 : 400,
                                             italic: (Int(row["italic"] ?? "") ?? 0) != 0)
                    }
                }
            } else if section == "[events]" {
                if tag == "format" { eventFormat = fields(content) }
                else if tag == "dialogue" {
                    guard eventFormat.last == "text" else {
                        warnings.insert("字幕的 Text 字段位置不受支持。"); continue
                    }
                    let values = content.split(separator: ",", maxSplits: max(0, eventFormat.count - 1),
                                               omittingEmptySubsequences: false).map(String.init)
                    guard values.count == eventFormat.count else {
                        warnings.insert("有对白行字段不完整，未能解析。"); continue
                    }
                    let row = dictionary(eventFormat, values)
                    events.append(((row["style"] ?? "Default").trimmingCharacters(in: .whitespaces), row["text"] ?? ""))
                }
            }
        }
        var requests: [String: FontRequest] = [:]
        for (styleName, text) in events {
            guard let base = styles[styleName] ?? styles["Default"] else {
                warnings.insert("对白引用的样式不存在：\(styleName)"); continue
            }
            var current = base, drawing = false, cursor = text.startIndex
            func collect(_ fragment: Substring) {
                let visible = fragment.replacingOccurrences(of: "\\N", with: "")
                    .replacingOccurrences(of: "\\n", with: "").replacingOccurrences(of: "\\h", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !drawing && !visible.isEmpty && !current.name.isEmpty {
                    let req = FontRequest(name: current.name, weight: current.weight, italic: current.italic)
                    requests[req.id] = req
                }
            }
            while cursor < text.endIndex {
                guard let open = text[cursor...].firstIndex(of: "{"),
                      let close = text[open...].firstIndex(of: "}") else { collect(text[cursor...]); break }
                collect(text[cursor..<open])
                let overrides = String(text[text.index(after: open)..<close])
                // Parenthesized effects cannot contain valid font-name/style-reset overrides.
                let stripped = overrides.replacingOccurrences(of: #"\\t\([^)]*\)"#, with: "", options: .regularExpression)
                for rawTag in stripped.split(separator: "\\", omittingEmptySubsequences: true) {
                    let t = String(rawTag).trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("fn") {
                        let name = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        current.name = name.isEmpty ? base.name : name
                    } else if t.hasPrefix("r") {
                        let name = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
                        current = name.isEmpty ? base : (styles[name] ?? base)
                        drawing = false
                    } else if t.hasPrefix("b"), let v = Int(t.dropFirst()) {
                        current.weight = v == 0 ? 400 : (v == 1 || v == -1 ? 700 : max(1, min(1000, v)))
                    } else if t.hasPrefix("i"), let v = Int(t.dropFirst()) { current.italic = v != 0 }
                    else if t.hasPrefix("p"), let v = Int(t.dropFirst()) { drawing = v != 0 }
                }
                cursor = text.index(after: close)
            }
        }
        if events.isEmpty { warnings.insert("没有找到可解析的 ASS/SSA 对白。") }
        return SubtitleAnalysis(requests: requests.values.sorted { $0.id < $1.id }, warnings: warnings.sorted())
    }

    private static func fields(_ text: String) -> [String] {
        text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }
    private static func dictionary(_ keys: [String], _ values: [String]) -> [String: String] {
        Dictionary(zip(keys, values), uniquingKeysWith: { _, new in new })
    }
}
