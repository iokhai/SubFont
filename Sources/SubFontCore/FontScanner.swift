import Foundation

struct KnownFile: Sendable { let fingerprint: FileFingerprint; let parserVersion: Int }
struct ScannedFile: Sendable {
    let path: String
    let fingerprint: FileFingerprint
    let faces: [FontFace]
    let error: String?
}
struct ScanBatch: Sendable {
    var files: [ScannedFile] = []
    var examined = 0
}
struct ScanCompletion: Sendable {
    let removed: [String]
    let errors: [String]
    let complete: Bool
}

enum FontScanner {
    static func scan(root: URL, scope: String, known: [String: KnownFile], force: Bool,
                     receive: @Sendable (ScanBatch) async throws -> Void) async throws -> ScanCompletion {
        let granted = root.startAccessingSecurityScopedResource()
        defer { if granted { root.stopAccessingSecurityScopedResource() } }
        let directory = scope.isEmpty ? root : root.appendingPathComponent(scope, isDirectory: true)
        // Listing the root first distinguishes an offline/unreadable root from a removed subtree.
        _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let issues = ScanIssues()
        var seen = Set<String>(), batch = ScanBatch()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in issues.append("\(url.lastPathComponent)：\(error.localizedDescription)"); return true }
        ) else { throw SubFontError.message("无法读取目录：\(directory.path)") }
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            do {
                let resource = try url.resourceValues(forKeys: keys)
                if resource.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard resource.isRegularFile == true,
                      FontMetadataReader.extensions.contains(url.pathExtension.lowercased()) else { continue }
                let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
                guard url.path.hasPrefix(prefix) else { continue }
                let relative = String(url.path.dropFirst(prefix.count))
                seen.insert(relative)
                batch.examined += 1
                let before = try FileFingerprint.read(url)
                if !force, let cached = known[relative], cached.fingerprint == before,
                   cached.parserVersion == FontMetadataReader.version {
                    // No font-table reads for unchanged files.
                } else {
                    var faces: [FontFace] = [], parseError: String?
                    do { faces = try FontMetadataReader.read(url) } catch { parseError = error.localizedDescription }
                    let after = try FileFingerprint.read(url)
                    if before == after {
                        batch.files.append(ScannedFile(path: relative, fingerprint: after, faces: faces, error: parseError))
                    } else {
                        issues.append("\(relative)：文件正在变化，将在下次更新时重试。")
                    }
                }
                if batch.examined >= 64 {
                    try await receive(batch)
                    batch = ScanBatch()
                }
            } catch is CancellationError { throw CancellationError() }
            catch { issues.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        if batch.examined > 0 || !batch.files.isEmpty { try await receive(batch) }
        let errors = issues.values
        return ScanCompletion(removed: errors.isEmpty ? known.keys.filter { !seen.contains($0) } : [],
                              errors: errors, complete: errors.isEmpty)
    }
}

private final class ScanIssues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.withLock { if storage.count < 100 { storage.append(value) } } }
    var values: [String] { lock.withLock { storage } }
}
