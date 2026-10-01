import Foundation
import SubFontCore

final class IndexTests: CheckCase, @unchecked Sendable {
    private func setup() throws -> (URL, URL, FontIndex) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("Fonts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = try FontIndex(databaseURL: base.appendingPathComponent("index.sqlite"))
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (base, root, index)
    }
    private func fixture(_ name: String = "SubFontTest-Regular", extension ext: String = "ttf") -> URL {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!
    }
    func testMetadataAndCollection() throws {
        let faces = try FontMetadataReader.read(fixture())
        expectEqual(faces.count, 1)
        expectEqual(faces[0].postScriptName, "SubFontTestFixture-Regular")
        expectEqual(faces[0].weight, 400)
        expectTrue(faces[0].names.contains { $0.name == "SubFont Test Fixture" })
        expectTrue(faces[0].names.contains { $0.name == "字幕字体测试" })
        expectTrue(faces[0].names.contains { $0.name == "SubFont Unicode Alias" })
        let collection = try FontMetadataReader.read(fixture("SubFontTest-Collection", extension: "ttc"))
        expectEqual(collection.count, 2)
        expectEqual(collection.map(\.index), [0, 1])
        expectEqual(Set(collection.map(\.family)), ["SubFont Test Fixture", "SubFont Second Fixture"])
    }
    func testIncrementalChangesAndPersistence() async throws {
        let (base, root, index) = try setup()
        let first = root.appendingPathComponent("a.ttf")
        try FileManager.default.copyItem(at: fixture(), to: first)
        try await index.addDirectory(root)
        await index.waitUntilIdle()
        let initial = try await index.snapshot()
        expectEqual(initial.files, 1)
        expectEqual(initial.parsedFiles, 1)
        let request = FontRequest(name: "SUBFONT TEST FIXTURE")
        let matches = try await index.candidates(for: [request])
        expectEqual(matches[request.id]?.count, 1)
        let chineseRequest = FontRequest(name: "字幕字体测试")
        let chineseMatches = try await index.candidates(for: [chineseRequest])
        expectEqual(chineseMatches[chineseRequest.id]?.first?.postScriptName, "SubFontTestFixture-Regular")

        try await index.refresh()
        await index.waitUntilIdle()
        let unchanged = try await index.snapshot()
        expectEqual(unchanged.parsedFiles, 0, "Unchanged files must not be reparsed")
        let second = root.appendingPathComponent("b.ttf")
        try FileManager.default.copyItem(at: fixture("SubFontTest-Second"), to: second)
        try await index.refresh()
        await index.waitUntilIdle()
        let added = try await index.snapshot()
        expectEqual(added.files, 2)
        expectEqual(added.parsedFiles, 1)

        try FileManager.default.removeItem(at: first)
        try await index.refresh()
        await index.waitUntilIdle()
        let removed = try await index.candidates(for: [request])
        expectTrue(removed[request.id]?.isEmpty == true)
        let reopened = try FontIndex(databaseURL: base.appendingPathComponent("index.sqlite"))
        let persisted = try await reopened.snapshot()
        expectEqual(persisted.files, 1)
    }
    func testBadFileAndOfflineDirectoryPreserveRecords() async throws {
        let (_, root, index) = try setup()
        try FileManager.default.copyItem(at: fixture(), to: root.appendingPathComponent("good.ttf"))
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("broken.otf"))
        try await index.addDirectory(root)
        await index.waitUntilIdle()
        let initial = try await index.snapshot()
        expectEqual(initial.files, 2)
        expectEqual(initial.failedFiles, 1)
        expectFalse(initial.errors.isEmpty)
        // Removal is intentional here; a missing root must not purge the font catalog.
        try FileManager.default.removeItem(at: root)
        try await index.refresh()
        await index.waitUntilIdle()
        let offline = try await index.snapshot()
        expectEqual(offline.files, 2)
        expectFalse(offline.roots[0].available)
    }
    func testWatcherIndexesNewFontWithoutManualRefresh() async throws {
        let (_, root, index) = try setup()
        try await index.addDirectory(root)
        await index.waitUntilIdle()
        try FileManager.default.copyItem(at: fixture(), to: root.appendingPathComponent("new.ttf"))
        let request = FontRequest(name: "SubFont Test Fixture")
        var found = false
        for _ in 0..<60 {
            let matches = try await index.candidates(for: [request])
            if matches[request.id]?.isEmpty == false { found = true; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        expectTrue(found, "FSEvents must update the index without a refresh action")
    }
    func testMalformedFontIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bad.ttf")
        try Data(repeating: 0xFF, count: 128).write(to: url)
        expectThrows(try FontMetadataReader.read(url))
        let source = try Data(contentsOf: fixture())
        try source.prefix(30).write(to: url)
        expectThrows(try FontMetadataReader.read(url))
    }
}
