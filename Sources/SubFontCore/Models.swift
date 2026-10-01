import Foundation
import Darwin

public enum FontName {
    public static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

public struct FontRequest: Hashable, Sendable, Identifiable {
    public let name: String
    public let weight: Int
    public let italic: Bool
    public var id: String { "\(FontName.key(name))|\(weight)|\(italic)" }
    public init(name: String, weight: Int = 400, italic: Bool = false) {
        self.name = name.hasPrefix("@") ? String(name.dropFirst()) : name
        self.weight = weight
        self.italic = italic
    }
    public var styleDescription: String {
        [weight >= 600 ? "粗体" : "常规", italic ? "斜体" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

public struct FontAlias: Hashable, Sendable {
    public let name: String
    public let kind: Int
    public let language: Int
    public init(name: String, kind: Int, language: Int = 0) {
        self.name = name; self.kind = kind; self.language = language
    }
}

public struct FontFace: Sendable {
    public let index: Int
    public let postScriptName: String
    public let family: String
    public let weight: Int
    public let italic: Bool
    public let revision: Int64
    public let names: [FontAlias]
}

public struct FileFingerprint: Equatable, Codable, Sendable {
    public let size: Int64
    public let modified: Int64
    public let changed: Int64
    public let identity: String
    public static func read(_ url: URL) throws -> Self {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ p in p.map { lstat($0, &info) } ?? -1 }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw SubFontError.message("不是普通文件：\(url.lastPathComponent)") }
        return Self(size: info.st_size,
                    modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                    changed: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec),
                    identity: "\(info.st_dev):\(info.st_ino)")
    }
}

public struct FontRoot: Identifiable, Sendable {
    public let id: String
    public let url: URL
    public let available: Bool
    public let issue: String?
}

public struct IndexSnapshot: Sendable {
    public var roots: [FontRoot] = []
    public var files = 0
    public var faces = 0
    public var failedFiles = 0
    public var scanning = false
    public var scannedFiles = 0
    public var parsedFiles = 0
    public var currentDirectory = ""
    public var errors: [String] = []
    public init() {}
}

public struct FontCandidate: Sendable {
    public let url: URL
    public let fingerprint: FileFingerprint
    public let faceIndex: Int
    public let postScriptName: String
    public let family: String
    public let weight: Int
    public let italic: Bool
    public let revision: Int64
    public let matchedName: String
    public let nameKind: Int
}

public enum SubFontError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

public enum SubFontPaths {
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SubFont", isDirectory: true)
    }
}
