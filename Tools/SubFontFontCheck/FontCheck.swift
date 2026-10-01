import Foundation
import AppKit
import CoreText
import CryptoKit
import SubFontCore

/// An opt-in real-font integration check. It uses the same core as the installed app,
/// persists the requested font-library root, and cleans up its own temporary registrations.
@main
struct FontCheck {
    struct Probe: Codable, Sendable, Equatable {
        let postScriptName: String
        let sampleCovered: Bool
    }
    private static let sample = "春风又绿江南岸，明月何时照我还。AaBbCc 0123456789"

    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.first == "--probe", args.count >= 2 {
                let result = try probe(args[1], image: args.count > 2 ? URL(fileURLWithPath: args[2]) : nil)
                print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
                return
            }
            guard args.count == 2 else {
                throw SubFontError.message("Usage: swift run SubFontFontCheck <font-library-directory> <downloaded-font>")
            }
            try await check(root: URL(fileURLWithPath: args[0], isDirectory: true),
                            stagedFont: URL(fileURLWithPath: args[1]))
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func check(root: URL, stagedFont: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let faces = try FontMetadataReader.read(stagedFont)
        guard let face = faces.first, !face.family.isEmpty, !face.postScriptName.isEmpty else {
            throw SubFontError.message("The downloaded font has no usable names")
        }
        let target = root.appendingPathComponent(stagedFont.lastPathComponent)
        let subtitle = root.appendingPathComponent("SubFont-test.ass")
        let image = root.appendingPathComponent("SubFont-font-preview.png")
        let report = root.appendingPathComponent("SubFont-test-report.json")
        let script = """
        [Script Info]
        Title: SubFont third-party font test
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,\(face.family),60,&H00FFFFFF,&H00FFFFFF,&H00101010,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,40,40,60,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,第三方字体加载测试：春风又绿江南岸。
        Dialogue: 0,0:00:05.00,0:00:10.00,Default,,0,0,0,,{\\fn\(face.postScriptName)}明月何时照我还。AaBbCc 0123456789

        """
        if FileManager.default.fileExists(atPath: subtitle.path) {
            guard try String(contentsOf: subtitle, encoding: .utf8) == script else {
                throw SubFontError.message("Existing test subtitle differs; it was not overwritten")
            }
        } else { try script.write(to: subtitle, atomically: true, encoding: .utf8) }
        let analysis = try ASSParser.read(subtitle)
        guard analysis.warnings.isEmpty, analysis.requests.count == 2 else {
            throw SubFontError.message("Subtitle analysis did not return the two expected names")
        }
        let index = try FontIndex(databaseURL: SubFontPaths.applicationSupport.appendingPathComponent("index.sqlite"))
        try await index.start()
        let rootID = try await index.addDirectory(root)
        await index.waitUntilIdle()
        let alreadyPresent = FileManager.default.fileExists(atPath: target.path)
        if alreadyPresent {
            guard try digest(target) == digest(stagedFont) else {
                throw SubFontError.message("A different font already exists at the destination")
            }
            try await index.refresh()
        } else {
            // The watcher is already running: discovery must happen without a manual refresh.
            let part = root.appendingPathComponent(".subfont-download-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: stagedFont, to: part)
            try FileManager.default.moveItem(at: part, to: target)
        }
        let began = Date()
        var matches: [String: [FontCandidate]] = [:]
        while Date().timeIntervalSince(began) < 30 {
            matches = try await index.candidates(for: analysis.requests)
            if analysis.requests.allSatisfy({ matches[$0.id]?.isEmpty == false }) { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard analysis.requests.allSatisfy({ matches[$0.id]?.isEmpty == false }) else {
            throw SubFontError.message("The live index did not discover the third-party font")
        }
        await index.waitUntilIdle()
        let discoverySeconds = Date().timeIntervalSince(began)
        let fingerprint = try digest(target)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SubFont-real-font-\(UUID().uuidString)")
        let session = try FontSession(directory: temporary)
        var before: [String: [Probe]] = [:], during: [String: [Probe]] = [:], after: [String: [Probe]] = [:]
        var registrations = 0
        do {
            for request in analysis.requests { before[request.name] = try childProbe(request.name) }
            for request in analysis.requests {
                guard let candidate = matches[request.id]?.first, candidate.url.standardizedFileURL == target.standardizedFileURL else {
                    throw SubFontError.message("The selected font was not the requested test file")
                }
                try await session.register(candidate, for: request)
            }
            registrations = await session.count
            for (i, request) in analysis.requests.enumerated() {
                let result = try childProbe(request.name, image: i == 0 ? image : nil)
                guard !result.isEmpty, result.contains(where: { $0.sampleCovered }) else {
                    throw SubFontError.message("Another process could not use the font: \(request.name)")
                }
                during[request.name] = result
            }
            let cleanup = await session.unloadAll()
            guard cleanup.isEmpty else { throw SubFontError.message(cleanup.joined(separator: "\n")) }
            for request in analysis.requests {
                after[request.name] = try childProbe(request.name)
                guard after[request.name] == before[request.name] else {
                    throw SubFontError.message("Font availability did not return to its pre-test state")
                }
            }
            guard try digest(target) == fingerprint else { throw SubFontError.message("Source font changed during the test") }
            try FileManager.default.removeItem(at: temporary)
        } catch {
            let cleanup = await session.unloadAll()
            if cleanup.isEmpty { try? FileManager.default.removeItem(at: temporary) }
            throw error
        }
        // FSEvents batches delivery (0.6 s) and the index debounces it (0.5 s).
        // Let the font's creation events drain before measuring an unchanged scan.
        try await Task.sleep(for: .seconds(2))
        await index.waitUntilIdle()
        try await index.refresh()
        await index.waitUntilIdle()
        let snapshot = try await index.snapshot()
        guard snapshot.parsedFiles == 0, snapshot.roots.contains(where: { $0.id == rootID && $0.available }) else {
            throw SubFontError.message("Unchanged-file check failed: reparsed=\(snapshot.parsedFiles), scanning=\(snapshot.scanning), roots=\(snapshot.roots.map { "\($0.url.path): \($0.available)" }), errors=\(snapshot.errors)")
        }
        let encoder = JSONEncoder()
        let probeData = try encoder.encode(["before": before, "during": during, "after": after])
        let probes = try JSONSerialization.jsonObject(with: probeData)
        let output: [String: Any] = [
            "passed": true, "font_library": root.path, "font_file": target.path,
            "font_family": face.family, "postscript_name": face.postScriptName,
            "font_sha256": fingerprint, "subtitle": subtitle.path, "preview": image.path,
            "automatic_discovery_tested": !alreadyPresent, "discovery_seconds": discoverySeconds,
            "registered_private_copies": registrations, "unchanged_files_reparsed": snapshot.parsedFiles,
            "configured_root_id": rootID, "cross_process_probes": probes,
            "cleanup_passed": true, "original_font_unchanged": true,
            "scope": "Core engine and independent Core Text rendering; not GUI automation"
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: report, options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
    private static func childProbe(_ name: String, image: URL? = nil) throws -> [Probe] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--probe", name] + (image.map { [$0.path] } ?? [])
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SubFontError.message("Independent font probe failed") }
        return try JSONDecoder().decode([Probe].self, from: data)
    }
    @MainActor private static func probe(_ name: String, image: URL?) throws -> [Probe] {
        let descriptors = [kCTFontFamilyNameAttribute, kCTFontDisplayNameAttribute, kCTFontNameAttribute].map {
            CTFontDescriptorCreateWithAttributes([$0: name] as CFDictionary)
        }
        let collection = CTFontCollectionCreateWithFontDescriptors(descriptors as CFArray,
            [kCTFontCollectionRemoveDuplicatesOption: 1] as CFDictionary)
        let matches = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        var output: [Probe] = []
        for (i, descriptor) in matches.enumerated() {
            let font = CTFontCreateWithFontDescriptor(descriptor, 54, nil)
            let characters = Array(sample.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            let covered = CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
            output.append(Probe(postScriptName: CTFontCopyPostScriptName(font) as String, sampleCovered: covered))
            if i == 0, let image { try render(font: font, name: name, destination: image) }
        }
        return output.sorted { $0.postScriptName < $1.postScriptName }
    }
    @MainActor private static func render(font: CTFont, name: String, destination: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.setFillColor(CGColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1440, height: 600))
        func line(_ text: String, _ typeface: CTFont, _ y: CGFloat, _ color: CGColor) {
            let string = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): typeface,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ])
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 64, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        let small = CTFontCreateUIFontForLanguage(.system, 24, nil)!
        let heading = CTFontCreateUIFontForLanguage(.system, 32, nil)!
        let dark = CGColor(red: 0.10, green: 0.16, blue: 0.25, alpha: 1)
        let muted = CGColor(red: 0.35, green: 0.40, blue: 0.48, alpha: 1)
        line("SubFont · 第三方字体加载测试", heading, 522, dark)
        line(name + "  /  Regular", small, 473, muted)
        context.setFillColor(CGColor(red: 0.15, green: 0.48, blue: 0.81, alpha: 1))
        context.fill(CGRect(x: 64, y: 437, width: 1312, height: 2))
        line("春风又绿江南岸，", font, 330, dark)
        line("明月何时照我还。", font, 245, dark)
        line("AaBbCc 0123456789 · 字幕字体测试", CTFontCreateCopyWithAttributes(font, 36, nil, nil), 151, dark)
        line("由独立 Core Text 进程使用临时注册的字体渲染", small, 65, muted)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SubFontError.message("Could not render font preview")
        }
        try data.write(to: destination, options: .atomic)
    }
}
