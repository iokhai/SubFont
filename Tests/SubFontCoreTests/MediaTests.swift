import Foundation
import SubFontCore
import CZlib

final class MediaTests: CheckCase, @unchecked Sendable {
    private func setup() throws -> (URL, SubtitleSourceReader) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SubFont-media-check-" + UUID().uuidString)
        let reader = try SubtitleSourceReader(directory: root.appendingPathComponent("Cache"))
        addTeardownBlock { try? await reader.cleanUp(); try? FileManager.default.removeItem(at: root) }
        return (root, reader)
    }
    private func fixture(_ name: String, _ ext: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!
    }
    func testRealMatroskaAttachmentsAndLifecycle() async throws {
        let (root, reader) = try setup()
        let video = fixture("EmbeddedSubtitles", "mkv")
        let original = try Data(contentsOf: video)
        let result = try await reader.read(video)
        expectTrue(result.warnings.isEmpty, result.warnings.joined(separator: "\n"))
        expectEqual(Set(result.requests.map(\.name)), Set(["SubFont Test Fixture", "SubFont CFF Fixture", "SubFont Second Fixture"]))
        expectFalse(result.requests.contains { $0.name == "Do Not Load This Font" })
        expectEqual(result.attachmentNames.count, 3)
        let session = try FontSession(directory: root.appendingPathComponent("RegisteredFonts"))
        addTeardownBlock { _ = await session.unloadAll() }
        for request in result.requests {
            let font = try requireValue(result.candidates(for: request).first)
            expectTrue(font.url.path.hasPrefix(root.appendingPathComponent("Cache").path + "/media-"))
            expectFalse(font.url.lastPathComponent.contains("outside"), "Attachment names must never control extraction paths")
            try await session.register(font, for: request)
            expectTrue(SystemFonts.contains(request), "Attached font must be usable by Core Text")
        }
        let count = await session.count
        expectEqual(count, 3, "Only needed attached fonts should be registered")
        _ = try await reader.read(video)
        let reads = await reader.videoReads
        expectEqual(reads, 1, "Rechecking the library must reuse video analysis")
        let errors = await session.unloadAll()
        expectTrue(errors.isEmpty)
        try await reader.cleanUp()
        for request in result.requests { expectFalse(SystemFonts.contains(request)) }
        expectTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Cache").path).isEmpty)
        expectEqual(try Data(contentsOf: video), original, "Container must remain unchanged")
    }
    func testCacheInvalidationAndTimedText() async throws {
        let (root, reader) = try setup()
        let file = root.appendingPathComponent("changing.mp4")
        try FileManager.default.copyItem(at: fixture("EmbeddedSubtitles", "mkv"), to: file)
        let first = try await reader.read(file)
        expectEqual(first.attachmentNames.count, 3)
        let next = try Data(contentsOf: fixture("TimedText", "mp4"))
        try next.write(to: file, options: .atomic)
        let changed = try await reader.read(file)
        expectTrue(changed.warnings.isEmpty, changed.warnings.joined(separator: "\n"))
        expectEqual(changed.requests.map(\.name), ["SubFont Second Fixture"])
        expectTrue(changed.embeddedFonts.isEmpty)
        let reads = await reader.videoReads
        expectEqual(reads, 2)
        for candidate in first.embeddedFonts { expectFalse(FileManager.default.fileExists(atPath: candidate.url.path)) }
    }
    func testCompressedSSAAndHeaderStripping() async throws {
        let (root, reader) = try setup()
        let header = Data(MediaFixture.header("Compressed Font", ssa: true).utf8)
        let packet = Data("0,0,Default,,0,0,0,,A{\\fnInline Font}A".utf8)
        let compressed = MediaFixture.track(1, codec: "S_TEXT/SSA", header: try MediaFixture.compress(header),
            encoding: MediaFixture.encoding(scope: 3, algorithm: 0))
        let stripped = MediaFixture.track(2, header: Data(MediaFixture.header("Stripped Font").utf8),
            encoding: MediaFixture.encoding(scope: 1, algorithm: 3, settings: Data("0,0,".utf8)))
        let movie = MediaFixture.movie(tracks: compressed + stripped, clusters:
            MediaFixture.cluster(MediaFixture.block(1, try MediaFixture.compress(packet)) +
                                 MediaFixture.block(2, Data("Default,,0,0,0,,A".utf8))))
        let url = root.appendingPathComponent("compressed.mkv")
        try movie.write(to: url)
        let result = try await reader.read(url)
        expectTrue(result.warnings.isEmpty, result.warnings.joined(separator: "\n"))
        expectEqual(Set(result.requests.map(\.name)), Set(["Compressed Font", "Inline Font", "Stripped Font"]))
    }
    func testUnknownClustersStateChangesAndLacing() async throws {
        let (root, reader) = try setup()
        let first = Data("0,0,Default,,0,0,0,,{\\fnLace AAA}A".utf8)
        let second = Data("1,0,Default,,0,0,0,,{\\fnLace BBB}A".utf8)
        expectEqual(first.count, second.count)
        var blocks = Data()
        for mode: UInt8 in [2, 4, 6] {
            var lace = Data([1])
            if mode == 2 { lace += Data([UInt8(first.count)]) }
            if mode == 6 { lace += MediaFixture.vint(UInt64(first.count)) }
            blocks += MediaFixture.block(1, lace + first + second, flags: mode)
        }
        let before = MediaFixture.element(0xA0, MediaFixture.block(1, Data("2,0,Default,,0,0,0,,A".utf8), group: true))
        let changed = MediaFixture.element(0xA0,
            MediaFixture.element(0xA4, Data(MediaFixture.header("Changed Header Font").utf8)) +
            MediaFixture.block(1, Data("3,0,Default,,0,0,0,,A".utf8), group: true))
        let clusters = MediaFixture.cluster(blocks + before, unknown: true) + MediaFixture.cluster(changed)
        let movie = MediaFixture.movie(tracks: MediaFixture.track(1), clusters: clusters, unknown: true, tracksAfterClusters: true)
        let url = root.appendingPathComponent("unknown-size.mkv")
        try movie.write(to: url)
        let result = try await reader.read(url)
        expectTrue(result.warnings.isEmpty, result.warnings.joined(separator: "\n"))
        expectEqual(Set(result.requests.map(\.name)), Set(["Fixture Font", "Changed Header Font", "Lace AAA", "Lace BBB"]))
    }
    func testUnsupportedTracksAndMalformedContainers() async throws {
        let (root, reader) = try setup()
        let url = root.appendingPathComponent("unsupported.mkv")
        try MediaFixture.movie(tracks: MediaFixture.track(1, codec: "S_HDMV/PGS") +
            MediaFixture.track(2, codec: "S_TEXT/UTF8"), clusters: Data()).write(to: url)
        let result = try await reader.read(url)
        expectTrue(result.requests.isEmpty)
        expectTrue(result.warnings.contains { $0.contains("位图字幕无需加载字体") })
        expectTrue(result.warnings.contains { $0.contains("纯文本字幕未声明字体") })
        let valid = MediaFixture.movie(tracks: MediaFixture.track(1), clusters: MediaFixture.cluster(MediaFixture.block(1, Data("0,0,Default,,0,0,0,,A".utf8))))
        for cutoff in [0, 1, 3, 8, valid.count - 1] {
            let damaged = root.appendingPathComponent("truncated-\(cutoff).mkv")
            try valid.prefix(cutoff).write(to: damaged)
            do { _ = try await reader.read(damaged); expectTrue(false, "Truncation at \(cutoff) must fail") }
            catch { }
        }
        let oversized = root.appendingPathComponent("overflow.mp4")
        try (Data([0, 0, 0, 1]) + Data("moov".utf8) + Data(repeating: 255, count: 8)).write(to: oversized)
        do { _ = try await reader.read(oversized); expectTrue(false, "Overflowing box size must fail") }
        catch { }
        // A damaged subtitle block must be reported rather than silently marked complete.
        let malformed = root.appendingPathComponent("broken-block.mkv")
        try MediaFixture.movie(tracks: MediaFixture.track(1), clusters:
            MediaFixture.cluster(MediaFixture.block(1, Data([1, 127]), flags: 6))).write(to: malformed)
        let bad = try await reader.read(malformed)
        expectTrue(bad.requests.isEmpty)
        expectTrue(bad.warnings.contains { $0.contains("解析不完整") })
        // Deliberately invalid font bytes are ignored safely while subtitle requests survive.
        let attachment = MediaFixture.element(0x1941A469, MediaFixture.element(0x61A7,
            MediaFixture.element(0x466E, Data("../../bad.ttf".utf8)) + MediaFixture.element(0x465C, Data([1, 2, 3]))))
        let badFont = root.appendingPathComponent("bad-font.mkv")
        try MediaFixture.movie(tracks: MediaFixture.track(1), clusters:
            MediaFixture.cluster(MediaFixture.block(1, Data("0,0,Default,,0,0,0,,A".utf8))) + attachment).write(to: badFont)
        let missing = try await reader.read(badFont)
        expectEqual(missing.requests.map(\.name), ["Fixture Font"])
        expectTrue(missing.embeddedFonts.isEmpty)
        expectFalse(missing.warnings.isEmpty)
    }
    func testLargeMovieSkipsPayloadAndCancellation() async throws {
        let (root, reader) = try setup()
        let source = try Data(contentsOf: fixture("TimedText", "mp4"))
        let url = root.appendingPathComponent("large.mp4")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let size: UInt64 = 5 * 1024 * 1024 * 1024
        try handle.write(contentsOf: source)
        try handle.write(contentsOf: Data([0, 0, 0, 1]) + Data("mdat".utf8) + MediaFixture.bigEndian(size, 8))
        try handle.truncate(atOffset: UInt64(source.count) + size)
        try handle.close()
        let result = try await reader.read(url)
        expectTrue(result.warnings.isEmpty, result.warnings.joined(separator: "\n"))
        expectEqual(result.requests.map(\.name), ["SubFont Second Fixture"])
        expectTrue(result.bytesRead < 16384, "Only subtitle sample data should be processed")
        let task = Task {
            try Task.checkCancellation()
            return try await reader.read(url)
        }
        task.cancel()
        do { _ = try await task.value; expectTrue(false, "Cancelled reads must exit") }
        catch is CancellationError { }
    }
    func testFragmentedMP4InlineFontsAndStyles() async throws {
        let (_, reader) = try setup()
        let result = try await reader.read(fixture("TimedTextStyled", "mp4"))
        expectTrue(result.warnings.isEmpty, result.warnings.joined(separator: "\n"))
        expectEqual(Set(result.requests.map(\.name)), Set(["SubFont Test Fixture", "SubFont CFF Fixture", "SubFont Second Fixture"]))
        let styled = try requireValue(result.requests.first { $0.name == "SubFont Second Fixture" })
        expectEqual(styled.weight, 700)
        expectTrue(styled.italic)
    }
    func testMatroskaSkipsLargeVideoBlocks() async throws {
        let (root, reader) = try setup()
        let url = root.appendingPathComponent("large.mkv")
        let videoTrack = MediaFixture.element(0xAE, MediaFixture.uint(0xD7, 2) + MediaFixture.uint(0x83, 1) +
            MediaFixture.element(0x86, Data("V_MPEG4/ISO/ASP".utf8)))
        let prefix = MediaFixture.movie(tracks: MediaFixture.track(1) + videoTrack, clusters: Data(), unknown: true) +
            MediaFixture.cluster(Data(), unknown: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: prefix)
        let size: UInt64 = 5 * 1024 * 1024 * 1024
        try handle.write(contentsOf: MediaFixture.bigEndian(0xA3, 1) + MediaFixture.vint(size))
        let payloadStart = try handle.offset()
        // Track 2 is not a subtitle track. Its payload must be skipped by offset.
        try handle.write(contentsOf: MediaFixture.vint(2) + Data([0, 0, 0]))
        try handle.truncate(atOffset: payloadStart + size)
        try handle.seek(toOffset: payloadStart + size)
        try handle.write(contentsOf: MediaFixture.block(1, Data("0,0,Default,,0,0,0,,A".utf8)))
        try handle.close()
        let result = try await reader.read(url)
        expectTrue(result.warnings.isEmpty, result.warnings.joined(separator: "\n"))
        expectEqual(result.requests.map(\.name), ["Fixture Font"])
        expectTrue(result.bytesRead < 4096, "The reader must seek past 5 GiB of non-subtitle payload")
    }
}

private enum MediaFixture {
    static func bigEndian(_ value: UInt64, _ count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func vint(_ value: UInt64) -> Data {
        let width = (1...8).first { value < (UInt64(1) << (7 * $0)) - 1 }!
        return bigEndian(value | UInt64(1) << (7 * width), width)
    }
    static func element(_ id: UInt64, _ data: Data, unknown: Bool = false) -> Data {
        let width = max(1, (64 - id.leadingZeroBitCount + 7) / 8)
        return bigEndian(id, width) + (unknown ? Data([255]) : vint(UInt64(data.count))) + data
    }
    static func uint(_ id: UInt64, _ value: UInt64) -> Data { element(id, bigEndian(value, 1)) }
    static func header(_ family: String = "Fixture Font", ssa: Bool = false) -> String {
        """
        [Script Info]
        ScriptType: \(ssa ? "v4.00" : "v4.00+")
        [\(ssa ? "V4 Styles" : "V4+ Styles")]
        Format: Name, Fontname, Bold, Italic
        Style: Default,\(family),0,0
        Style: Unused,Unused Font,0,0
        """
    }
    static func track(_ number: UInt64, codec: String = "S_TEXT/ASS", header: Data? = nil, encoding: Data = Data()) -> Data {
        element(0xAE, uint(0xD7, number) + uint(0x83, 0x11) + element(0x86, Data(codec.utf8)) +
                element(0x63A2, header ?? Data(Self.header().utf8)) + encoding)
    }
    static func encoding(scope: UInt64, algorithm: UInt64, settings: Data = Data()) -> Data {
        element(0x6D80, element(0x6240, uint(0x5032, scope) + uint(0x5033, 0) +
            element(0x5034, uint(0x4254, algorithm) + element(0x4255, settings))))
    }
    static func block(_ track: UInt64, _ packet: Data, flags: UInt8 = 0, group: Bool = false) -> Data {
        element(group ? 0xA1 : 0xA3, vint(track) + Data([0, 0, flags]) + packet)
    }
    static func cluster(_ data: Data, unknown: Bool = false) -> Data { element(0x1F43B675, uint(0xE7, 0) + data, unknown: unknown) }
    static func movie(tracks: Data, clusters: Data, unknown: Bool = false, tracksAfterClusters: Bool = false) -> Data {
        let table = element(0x1654AE6B, tracks)
        return element(0x1A45DFA3, element(0x4282, Data("matroska".utf8))) +
            element(0x18538067, tracksAfterClusters ? clusters + table : table + clusters, unknown: unknown)
    }
    static func compress(_ data: Data) throws -> Data {
        var output = [UInt8](repeating: 0, count: Int(compressBound(uLong(data.count))))
        var size = uLongf(output.count)
        let code = data.withUnsafeBytes { pointer in
            output.withUnsafeMutableBufferPointer { result in
                compress2(result.baseAddress, &size, pointer.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_BEST_SPEED)
            }
        }
        guard code == Z_OK else { throw SubFontError.message("Compression fixture failed") }
        return Data(output.prefix(Int(size)))
    }
}
