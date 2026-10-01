import Foundation
import CoreText

public enum SystemFonts {
    public static func contains(_ request: FontRequest) -> Bool {
        let attributes = [kCTFontFamilyNameAttribute, kCTFontDisplayNameAttribute, kCTFontNameAttribute]
        let queries = attributes.map {
            CTFontDescriptorCreateWithAttributes([$0: request.name] as CFDictionary)
        }
        let collection = CTFontCollectionCreateWithFontDescriptors(
            queries as CFArray, [kCTFontCollectionRemoveDuplicatesOption: 1] as CFDictionary)
        let matches = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        return matches.contains { descriptor in
            matchesRequest(CTFontCreateWithFontDescriptor(descriptor, 12, nil), request)
        }
    }

    private static func matchesRequest(_ font: CTFont, _ request: FontRequest) -> Bool {
        let key = FontName.key(request.name)
        let names = [kCTFontFamilyNameKey, kCTFontFullNameKey, kCTFontPostScriptNameKey]
        var matchesName = names.contains { attribute in
            if let name = CTFontCopyName(font, attribute), FontName.key(name as String) == key { return true }
            if let name = CTFontCopyLocalizedName(font, attribute, nil), FontName.key(name as String) == key { return true }
            return false
        }
        if !matchesName, let table = CTFontCopyTable(font, 0x6E616D65, []),
           let aliases = try? FontMetadataReader.decodeNames(table as Data) {
            matchesName = aliases.contains {
                [1, 4, 6, 16, 18, 21].contains($0.kind) && FontName.key($0.name) == key
            }
        }
        guard matchesName else { return false }
        var needed: CTFontSymbolicTraits = []
        if request.weight >= 600 { needed.insert(.traitBold) }
        if request.italic { needed.insert(.traitItalic) }
        if !needed.isEmpty {
            guard let styled = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, needed, needed),
                  CTFontGetSymbolicTraits(styled).contains(needed) else { return false }
            guard CTFontCopyFamilyName(styled) == CTFontCopyFamilyName(font) else { return false }
        }
        return true
    }
}

/// Registers only selected fonts, at login-session scope, from stable private copies.
/// A write-ahead ledger permits cleanup after a crash without touching installed fonts.
public actor FontSession {
    private struct Entry: Codable, Sendable {
        let source: String
        let fingerprint: FileFingerprint
        let cachedPath: String
        var alias: String?
        var faceIndex: Int?
    }
    private let directory: URL
    private let ledger: URL
    private var entries: [Entry]
    public var count: Int { entries.count }

    public init(directory: URL) throws {
        self.directory = directory
        ledger = directory.appendingPathComponent("registrations.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: ledger.path) {
            entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: ledger))
        } else { entries = [] }
    }

    public func register(_ candidate: FontCandidate, for request: FontRequest? = nil) throws {
        let externallyAvailable = !candidate.postScriptName.isEmpty &&
            SystemFonts.contains(FontRequest(name: candidate.postScriptName, weight: candidate.weight, italic: candidate.italic))
        if !externallyAvailable &&
            !entries.contains(where: { $0.source == candidate.url.path && $0.fingerprint == candidate.fingerprint && $0.alias == nil }) {
            try registerCopy(candidate)
        }
        if let request {
            let actualStyle = FontRequest(name: request.name, weight: candidate.weight, italic: candidate.italic)
            if !SystemFonts.contains(actualStyle) &&
                !entries.contains(where: { $0.source == candidate.url.path && $0.fingerprint == candidate.fingerprint &&
                    $0.alias == request.name && $0.faceIndex == candidate.faceIndex }) {
                try registerCopy(candidate, alias: request.name)
                guard SystemFonts.contains(actualStyle) else {
                    throw SubFontError.message("macOS 未能识别字体名称：\(request.name)")
                }
            }
        }
    }
    private func registerCopy(_ candidate: FontCandidate, alias: String? = nil) throws {
        guard try FileFingerprint.read(candidate.url) == candidate.fingerprint else {
            throw SubFontError.message("字体文件已经变化，请重新检查：\(candidate.url.lastPathComponent)")
        }
        let copy = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(alias == nil ? candidate.url.pathExtension : "otf")
        if let alias {
            try FontAliasBuilder.make(candidate: candidate, alias: alias).write(to: copy, options: .atomic)
        } else {
            try FileManager.default.copyItem(at: candidate.url, to: copy)
        }
        guard try FileFingerprint.read(candidate.url) == candidate.fingerprint else {
            try? FileManager.default.removeItem(at: copy)
            throw SubFontError.message("字体正在被修改，请稍后重新检查")
        }
        let entry = Entry(source: candidate.url.path, fingerprint: candidate.fingerprint, cachedPath: copy.path,
                          alias: alias, faceIndex: alias == nil ? nil : candidate.faceIndex)
        entries.append(entry)
        do { try persist() }
        catch {
            entries.removeLast()
            try? FileManager.default.removeItem(at: copy)
            throw error
        }
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(copy as CFURL, .session, &error) else {
            let message = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "字体注册失败"
            // This URL is our private copy. Cleanup cannot unregister the user's original files.
            var cleanupError: Unmanaged<CFError>?
            let removed = CTFontManagerUnregisterFontsForURL(copy as CFURL, .session, &cleanupError)
            let code = cleanupError.map { CFErrorGetCode($0.takeRetainedValue()) }
            if removed || code == CTFontManagerError.notRegistered.rawValue {
                entries.removeAll { $0.cachedPath == copy.path }
                try? persist()
                try? FileManager.default.removeItem(at: copy)
            }
            throw SubFontError.message(message)
        }
    }
    public func owns(_ candidate: FontCandidate) -> Bool {
        entries.contains { $0.source == candidate.url.path && $0.fingerprint == candidate.fingerprint }
    }
    public func unloadAll() -> [String] {
        var retained: [Entry] = [], failures: [String] = []
        for entry in entries {
            let url = URL(fileURLWithPath: entry.cachedPath)
            guard url.deletingLastPathComponent().resolvingSymlinksInPath() == directory.resolvingSymlinksInPath() else {
                failures.append("字体登记路径不属于 SubFont，已跳过。"); retained.append(entry); continue
            }
            var error: Unmanaged<CFError>?
            let removed = CTFontManagerUnregisterFontsForURL(url as CFURL, .session, &error)
            let value = error?.takeRetainedValue()
            if removed || value.map({ CFErrorGetCode($0) == CTFontManagerError.notRegistered.rawValue }) == true {
                try? FileManager.default.removeItem(at: url)
            } else {
                retained.append(entry)
                failures.append(value.map { CFErrorCopyDescription($0) as String } ?? "字体未能卸载")
            }
        }
        entries = retained
        do { try persist() } catch { failures.append(error.localizedDescription) }
        return failures
    }
    private func persist() throws {
        try JSONEncoder().encode(entries).write(to: ledger, options: .atomic)
    }
}
