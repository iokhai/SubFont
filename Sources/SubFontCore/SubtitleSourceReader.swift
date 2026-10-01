import Foundation

public struct SourceAnalysis: Sendable {
    public let requests: [FontRequest]
    public let warnings: [String]
    public let embeddedFonts: [FontCandidate]
    public let attachmentNames: [String: String]
    public let bytesRead: Int

    public func candidates(for request: FontRequest) -> [FontCandidate] {
        var seen = Set<String>()
        return embeddedFonts.filter { FontName.key($0.matchedName) == FontName.key(request.name) }.sorted {
            let left = Self.rank($0, request), right = Self.rank($1, request)
            if left != right { return left < right }
            if $0.postScriptName == $1.postScriptName && $0.revision != $1.revision { return $0.revision > $1.revision }
            return ($0.url.path, $0.faceIndex) < ($1.url.path, $1.faceIndex)
        }.filter { seen.insert("\($0.url.path)|\($0.faceIndex)").inserted }
    }
    private static func rank(_ candidate: FontCandidate, _ request: FontRequest) -> Int {
        let exact = candidate.matchedName.precomposedStringWithCanonicalMapping == request.name.precomposedStringWithCanonicalMapping
        let kind = candidate.nameKind == 6 ? 0 : (candidate.nameKind == 4 ? 1 : 2)
        return (exact ? 0 : 10_000) + kind * 2000 +
            (candidate.italic == request.italic ? 0 : 1000) + abs(candidate.weight - request.weight)
    }
}

/// Caches video analysis so font-library updates never repeatedly walk a movie.
/// Embedded fonts live in a private workspace and are copied again by FontSession before registration.
public actor SubtitleSourceReader {
    public static let subtitleExtensions: Set<String> = ["ass", "ssa"]
    public static let videoExtensions: Set<String> = ["mkv", "mka", "mks", "webm", "mp4", "m4v", "mov", "3gp"]
    public static let supportedExtensions = subtitleExtensions.union(videoExtensions)
    private struct Cached {
        let fingerprint: FileFingerprint
        let analysis: SourceAnalysis
        let directory: URL
    }
    private let directory: URL
    private var cached: [URL: Cached] = [:]
    public private(set) var videoReads = 0

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    /// Call after the previous font session is recovered, before accepting files.
    public func cleanUp() throws {
        cached = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            // Only remove workspaces created by this reader, including ones left after a crash.
            if url.lastPathComponent.hasPrefix("media-"), UUID(uuidString: String(url.lastPathComponent.dropFirst(6))) != nil {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
    public func read(_ url: URL) async throws -> SourceAnalysis {
        try Task.checkCancellation()
        if Self.subtitleExtensions.contains(url.pathExtension.lowercased()) {
            let result = try ASSParser.read(url)
            return SourceAnalysis(requests: result.requests, warnings: result.warnings, embeddedFonts: [], attachmentNames: [:], bytesRead: 0)
        }
        guard Self.videoExtensions.contains(url.pathExtension.lowercased()) else {
            throw SubFontError.message("请选择 ASS/SSA 字幕或 MKV、MP4、MOV 视频")
        }
        let url = url.standardizedFileURL
        let fingerprint = try FileFingerprint.read(url)
        if let previous = cached[url], previous.fingerprint == fingerprint { return previous.analysis }
        if let previous = cached.removeValue(forKey: url) { try? FileManager.default.removeItem(at: previous.directory) }
        let workspace = directory.appendingPathComponent("media-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let file = try MediaFileReader(url)
            let magic = try file.read(0, Int(min(4, file.size)))
            let matroska = magic == Data([0x1A, 0x45, 0xDF, 0xA3])
            var result = try await matroska ? MatroskaSubtitles(file: file).read() : MP4Subtitles.read(url)
            var fonts: [FontCandidate] = [], names: [String: String] = [:], total: UInt64 = 0
            let needed = Set(result.requests.map { FontName.key($0.name) })
            for attachment in result.attachments where !needed.isEmpty {
                try Task.checkCancellation()
                let size = attachment.range.upperBound - attachment.range.lowerBound
                guard size <= 64 * 1024 * 1024, total + size <= 256 * 1024 * 1024 else {
                    result.warnings.append("字体附件超过读取限制：\(attachment.name)")
                    continue
                }
                total += size
                // Never use attachment filenames as filesystem paths.
                let destination = workspace.appendingPathComponent(UUID().uuidString).appendingPathExtension(attachment.fileExtension)
                do {
                    try file.copy(attachment.range, to: destination)
                    let faces = try FontMetadataReader.read(destination)
                    let identity = try FileFingerprint.read(destination)
                    var matched = false
                    for face in faces {
                        for name in face.names where needed.contains(FontName.key(name.name)) {
                            matched = true
                            fonts.append(FontCandidate(url: destination, fingerprint: identity, faceIndex: face.index,
                                postScriptName: face.postScriptName, family: face.family, weight: face.weight,
                                italic: face.italic, revision: face.revision, matchedName: name.name, nameKind: name.kind))
                        }
                    }
                    if matched { names[destination.path] = "\(url.lastPathComponent) › \(attachment.name)" }
                    else { try FileManager.default.removeItem(at: destination) }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try? FileManager.default.removeItem(at: destination)
                    result.warnings.append("字体附件 \(attachment.name)：\(error.localizedDescription)")
                }
            }
            try Task.checkCancellation()
            guard try FileFingerprint.read(url) == fingerprint else {
                throw SubFontError.message("视频文件正在变化，请完成下载或复制后重试")
            }
            let analysis = SourceAnalysis(requests: result.requests, warnings: result.warnings,
                embeddedFonts: fonts, attachmentNames: names, bytesRead: matroska ? file.bytesRead : result.bytesRead)
            cached[url] = Cached(fingerprint: fingerprint, analysis: analysis, directory: workspace)
            videoReads += 1
            return analysis
        } catch {
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }
    }
}
