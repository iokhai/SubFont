import Foundation
import CoreText
import SubFontCore

final class SessionTests: CheckCase, @unchecked Sendable {
    func testNeverUnloadsAnExternallyRegisteredFont() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("Fonts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = Bundle.module.url(forResource: "SubFontTest-Regular", withExtension: "ttf", subdirectory: "Fixtures")!
        let source = root.appendingPathComponent("externally-registered.ttf")
        try FileManager.default.copyItem(at: fixture, to: source)
        let session = try FontSession(directory: base.appendingPathComponent("RegisteredFonts"))
        addTeardownBlock {
            _ = await session.unloadAll()
            var error: Unmanaged<CFError>?
            _ = CTFontManagerUnregisterFontsForURL(source as CFURL, .session, &error)
            _ = error?.takeRetainedValue()
            try? FileManager.default.removeItem(at: base)
        }
        var error: Unmanaged<CFError>?
        expectTrue(CTFontManagerRegisterFontsForURL(source as CFURL, .session, &error))
        _ = error?.takeRetainedValue()
        let index = try FontIndex(databaseURL: base.appendingPathComponent("index.sqlite"))
        try await index.addDirectory(root)
        await index.waitUntilIdle()
        let request = FontRequest(name: "字幕字体测试")
        let choices = try await index.candidates(for: [request])
        let candidate = try requireValue(choices[request.id]?.first)
        try await session.register(candidate, for: request)
        expectTrue(SystemFonts.contains(request))
        let failures = await session.unloadAll()
        expectTrue(failures.isEmpty)
        expectTrue(SystemFonts.contains(FontRequest(name: "SubFontTestFixture-Regular")),
                   "SubFont must not unregister a font owned by another application")
    }

    func testCompatibilityCopiesPreserveCollectionAndCFFGlyphs() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("Fonts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = try FontSession(directory: base.appendingPathComponent("RegisteredFonts"))
        addTeardownBlock { _ = await session.unloadAll(); try? FileManager.default.removeItem(at: base) }
        for (name, ext) in [("SubFontTest-Collection", "ttc"), ("SubFontTest-CFF", "otf")] {
            let source = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!
            try FileManager.default.copyItem(at: source, to: root.appendingPathComponent(name + "." + ext))
        }
        let index = try FontIndex(databaseURL: base.appendingPathComponent("index.sqlite"))
        try await index.addDirectory(root)
        await index.waitUntilIdle()
        for (name, alias) in [("SubFont Second Fixture", "集合字体兼容测试"), ("SubFont CFF Fixture", "曲线字体兼容测试")] {
            let original = FontRequest(name: name)
            let choices = try await index.candidates(for: [original])
            let candidate = try requireValue(choices[original.id]?.first)
            let before = try Data(contentsOf: candidate.url)
            let request = FontRequest(name: alias)
            try await session.register(candidate, for: request)
            expectTrue(SystemFonts.contains(request), "Alias unavailable: \(alias)")
            expectEqual(try Data(contentsOf: candidate.url), before, "Original font must remain untouched")
            let query = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: alias] as CFDictionary)
            let collection = CTFontCollectionCreateWithFontDescriptors([query] as CFArray, nil)
            let matches = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
            let descriptor = try requireValue(matches.first)
            let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            var character: UniChar = 65, glyph: CGGlyph = 0
            expectTrue(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
            expectEqual(glyph, 1)
            expectTrue(CTFontCreatePathForGlyph(font, glyph, nil) != nil, "Glyph outline must remain readable")
        }
        let failures = await session.unloadAll()
        expectTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testSessionRegistrationIsVisibleToAnotherProcessAndRecoverable() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("Fonts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = Bundle.module.url(forResource: "SubFontTest-Regular", withExtension: "ttf", subdirectory: "Fixtures")!
        let font = root.appendingPathComponent("test.ttf")
        try FileManager.default.copyItem(at: fixture, to: font)
        let index = try FontIndex(databaseURL: base.appendingPathComponent("index.sqlite"))
        try await index.addDirectory(root)
        await index.waitUntilIdle()
        let request = FontRequest(name: "SubFont Test Fixture")
        let candidates = try await index.candidates(for: [request])
        let candidate = try requireValue(candidates[request.id]?.first)
        let sessionDirectory = base.appendingPathComponent("RegisteredFonts")
        let session = try FontSession(directory: sessionDirectory)
        addTeardownBlock { _ = await session.unloadAll(); try? FileManager.default.removeItem(at: base) }
        try await session.register(candidate)
        expectTrue(SystemFonts.contains(request))
        try await session.register(candidate)
        let count = await session.count
        expectEqual(count, 1, "Opening another subtitle must reuse an owned font registration")
        let chinese = FontRequest(name: "字幕字体测试")
        try await session.register(candidate, for: chinese)
        expectTrue(SystemFonts.contains(chinese), "Chinese aliases must resolve through Core Text")
        let countWithAlias = await session.count
        try await session.register(candidate, for: chinese)
        let countAfterReuse = await session.count
        expectEqual(countAfterReuse, countWithAlias, "A compatibility alias must be reused")

        let probe = base.appendingPathComponent("probe.swift")
        try """
        import Foundation
        import CoreText
        let attributes = [kCTFontFamilyNameAttribute, kCTFontDisplayNameAttribute, kCTFontNameAttribute]
        let queries = attributes.map { CTFontDescriptorCreateWithAttributes([$0: CommandLine.arguments[1]] as CFDictionary) }
        let collection = CTFontCollectionCreateWithFontDescriptors(
            queries as CFArray, [kCTFontCollectionRemoveDuplicatesOption: 1] as CFDictionary)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        let names = descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
        print(names.sorted().joined(separator: ","))
        """.write(to: probe, atomically: true, encoding: .utf8)
        func runProbe(name: String = "SubFontTestFixture-Regular") throws -> String {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
            process.arguments = [probe.path, name]
            process.standardOutput = output
            try process.run()
            let result = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            expectEqual(process.terminationStatus, 0)
            return String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        expectEqual(try runProbe(), "SubFontTestFixture-Regular")
        let chineseName = try runProbe(name: "字幕字体测试")
        expectTrue(!chineseName.isEmpty, "A fresh process must find the Chinese family name")

        // A fresh loader reconstructs ownership from disk, as after an interrupted run.
        let recovered = try FontSession(directory: sessionDirectory)
        let errors = await recovered.unloadAll()
        expectTrue(errors.isEmpty, errors.joined(separator: "\n"))
        expectNotEqual(try runProbe(), "SubFontTestFixture-Regular")
        expectEqual(try runProbe(name: "字幕字体测试"), "")
        let data = try Data(contentsOf: sessionDirectory.appendingPathComponent("registrations.json"))
        expectEqual(String(decoding: data, as: UTF8.self), "[]")
    }
}
