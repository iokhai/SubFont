import Foundation
import SubFontCore
import Darwin

// This executable keeps verification usable with Command Line Tools alone;
// Apple's XCTest/Testing modules require a full Xcode installation on this host.
class CheckCase: @unchecked Sendable {
    private var teardown: [@Sendable () async throws -> Void] = []
    func addTeardownBlock(_ block: @escaping @Sendable () async throws -> Void) { teardown.append(block) }
    func finish() async {
        let blocks = teardown.reversed()
        teardown = []
        for block in blocks {
            do { try await block() } catch { CheckRecorder.shared.fail("Cleanup: \(error)") }
        }
    }
}
final class CheckRecorder: @unchecked Sendable {
    static let shared = CheckRecorder()
    private let lock = NSLock()
    private var failures: [String] = []
    var count: Int { lock.withLock { failures.count } }
    func fail(_ message: String) { lock.withLock { failures.append(message); print("  FAIL: \(message)") } }
}
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #fileID, line: Int = #line) {
    if actual != expected { CheckRecorder.shared.fail("\(file):\(line) \(message) expected \(expected), got \(actual)") }
}
func expectNotEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #fileID, line: Int = #line) {
    if actual == expected { CheckRecorder.shared.fail("\(file):\(line) \(message) unexpected \(actual)") }
}
func expectTrue(_ value: Bool, _ message: String = "", file: String = #fileID, line: Int = #line) {
    if !value { CheckRecorder.shared.fail("\(file):\(line) \(message)") }
}
func expectFalse(_ value: Bool, _ message: String = "", file: String = #fileID, line: Int = #line) {
    expectTrue(!value, message, file: file, line: line)
}
func expectThrows<T>(_ value: @autoclosure () throws -> T, file: String = #fileID, line: Int = #line) {
    do { _ = try value(); CheckRecorder.shared.fail("\(file):\(line) expected an error") } catch {}
}
func requireValue<T>(_ value: T?, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw SubFontError.message("\(file):\(line) required value is nil") }
    return value
}
@main
struct SubFontChecks {
    static func main() async {
        let parser = ParserTests(), index = IndexTests(), session = SessionTests()
        await run("ASS styles and overrides", parser) { try parser.testActualStylesAndOverrides() }
        await run("Unicode and vertical font names", parser) { try parser.testUnicodeEncodingsAndVerticalName() }
        await run("Drawing and unused fonts", parser) { parser.testDrawingAndOverriddenNamesAreNotRequired() }
        await run("Conservative name normalization", parser) { parser.testNormalizationPreservesSignificantCharacters() }
        await run("Font metadata and TTC faces", index) { try index.testMetadataAndCollection() }
        await run("Incremental indexing and persistence", index) { try await index.testIncrementalChangesAndPersistence() }
        await run("Corrupt files and offline roots", index) { try await index.testBadFileAndOfflineDirectoryPreserveRecords() }
        await run("Automatic FSEvents updates", index) { try await index.testWatcherIndexesNewFontWithoutManualRefresh() }
        await run("Malformed font bounds checks", index) { try index.testMalformedFontIsRejected() }
        await run("Cross-process registration, unload and recovery", session) {
            try await session.testSessionRegistrationIsVisibleToAnotherProcessAndRecoverable()
        }
        await run("TTC and CFF compatibility aliases preserve glyphs", session) {
            try await session.testCompatibilityCopiesPreserveCollectionAndCFFGlyphs()
        }
        await run("Externally registered fonts remain registered", session) {
            try await session.testNeverUnloadsAnExternallyRegisteredFont()
        }
        let failures = CheckRecorder.shared.count
        print(failures == 0 ? "All 12 checks passed." : "\(failures) failure(s).")
        exit(failures == 0 ? 0 : 1)
    }
    private static func run(_ name: String, _ test: CheckCase, body: @Sendable () async throws -> Void) async {
        print("CHECK: \(name)")
        let before = CheckRecorder.shared.count
        do { try await body() } catch { CheckRecorder.shared.fail("\(name): \(error)") }
        await test.finish()
        if CheckRecorder.shared.count == before { print("  PASS") }
    }
}
