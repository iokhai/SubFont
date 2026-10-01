import Foundation

public actor FontIndex {
    private let store: SQLiteStore
    private var watchers: [String: DirectoryWatcher] = [:]
    private var worker: Task<Void, Never>?
    private var debounce: [String: Task<Void, Never>] = [:]
    private var remoteAudit: Task<Void, Never>?
    private var pending: [String: [String: Bool]] = [:]
    private var invalidatedFiles: [String: Set<String>] = [:]
    private var progress = IndexSnapshot()
    private var handler: (@Sendable (IndexSnapshot) -> Void)?
    private var lastPublish = Date.distantPast

    public init(databaseURL: URL) throws { store = try SQLiteStore(url: databaseURL) }
    public func setHandler(_ handler: @escaping @Sendable (IndexSnapshot) -> Void) { self.handler = handler; publish() }
    public func start() throws {
        remoteAudit?.cancel()
        remoteAudit = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                guard let self else { return }
                await self.auditRemoteDirectories()
            }
        }
        // A metadata-only reconciliation on launch also recovers changes made while the app was closed.
        for root in try roots() {
            watch(root)
            try enqueue(root: root.id, scope: "", force: false)
        }
        publish()
    }
    private func auditRemoteDirectories() {
        do {
            for root in try roots() {
                let local = try? root.url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal
                if local != true { try enqueue(root: root.id, scope: "", force: false) }
            }
        } catch { progress.errors.append(error.localizedDescription); publish() }
    }
    @discardableResult public func addDirectory(_ url: URL) throws -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard try resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw SubFontError.message("请选择字体文件夹")
        }
        if let existing = try roots().first(where: { $0.url == resolved }) { return existing.id }
        let bookmark = try (try? resolved.bookmarkData(options: [.withSecurityScope])) ?? resolved.bookmarkData()
        let id = UUID().uuidString
        try store.execute("INSERT INTO roots(id,path,bookmark) VALUES(?,?,?)",
                          [.text(id), .text(resolved.path), .blob(bookmark)])
        watch(FontRoot(id: id, url: resolved, available: true, issue: nil))
        try enqueue(root: id, scope: "", force: false)
        publish()
        return id
    }
    public func removeDirectory(_ id: String) async throws {
        await waitUntilIdle()
        watchers.removeValue(forKey: id)?.stop()
        debounce.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)
        invalidatedFiles.removeValue(forKey: id)
        try store.execute("DELETE FROM roots WHERE id=?", [.text(id)])
        publish()
    }
    public func refresh(force: Bool = false) throws {
        for root in try roots() {
            watch(root)
            try enqueue(root: root.id, scope: "", force: force)
        }
    }
    public func waitUntilIdle() async {
        while let current = worker { await current.value }
    }
    public func snapshot() throws -> IndexSnapshot {
        var result = progress
        result.roots = try roots()
        let count = try store.rows("""
            SELECT (SELECT COUNT(*) FROM files) AS files,(SELECT COUNT(*) FROM faces) AS faces,
                   (SELECT COUNT(*) FROM files WHERE error IS NOT NULL) AS failed
            """).first ?? [:]
        result.files = Int(count["files"]?.int ?? 0)
        result.faces = Int(count["faces"]?.int ?? 0)
        result.failedFiles = Int(count["failed"]?.int ?? 0)
        let bad = try store.rows("SELECT path,error FROM files WHERE error IS NOT NULL LIMIT 20")
        result.errors = Array((progress.errors + bad.map { "\($0["path"]?.string ?? "")：\($0["error"]?.string ?? "")" }).prefix(100))
        return result
    }
    public func candidates(for requests: [FontRequest]) throws -> [String: [FontCandidate]] {
        var byKey: [String: [FontCandidate]] = [:]
        let keys = Array(Set(requests.map { FontName.key($0.name) })).sorted()
        for offset in stride(from: 0, to: keys.count, by: 80) {
            let chunk = Array(keys[offset..<min(keys.count, offset + 80)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try store.rows("""
              SELECT n.key,n.original,n.kind,f.face_index,f.ps_name,f.family,f.weight,f.italic,f.revision,
                     x.path,x.size,x.mtime,x.ctime,x.identity,r.path AS root_path
              FROM names n JOIN faces f ON f.id=n.face_id JOIN files x ON x.id=f.file_id
              JOIN roots r ON r.id=x.root_id
              WHERE n.key IN (\(placeholders)) AND x.error IS NULL AND r.available=1
              """, chunk.map(SQLValue.text))
            for row in rows {
                let value = FontCandidate(
                    url: URL(fileURLWithPath: row["root_path"]!.string).appendingPathComponent(row["path"]!.string),
                    fingerprint: fingerprint(row), faceIndex: Int(row["face_index"]!.int),
                    postScriptName: row["ps_name"]!.string, family: row["family"]!.string,
                    weight: Int(row["weight"]!.int), italic: row["italic"]!.int != 0,
                    revision: row["revision"]!.int, matchedName: row["original"]!.string,
                    nameKind: Int(row["kind"]!.int))
                byKey[row["key"]!.string, default: []].append(value)
            }
        }
        var output: [String: [FontCandidate]] = [:]
        for request in requests {
            var seen = Set<String>()
            output[request.id] = (byKey[FontName.key(request.name)] ?? []).sorted {
                let lhs = rank($0, request), rhs = rank($1, request)
                if lhs != rhs { return lhs < rhs }
                if $0.postScriptName == $1.postScriptName && $0.revision != $1.revision { return $0.revision > $1.revision }
                return ($0.url.path, $0.faceIndex) < ($1.url.path, $1.faceIndex)
            }.filter { seen.insert("\($0.url.path)|\($0.faceIndex)").inserted }
        }
        return output
    }
    private func rank(_ candidate: FontCandidate, _ request: FontRequest) -> Int {
        let exact = candidate.matchedName.precomposedStringWithCanonicalMapping == request.name.precomposedStringWithCanonicalMapping
        let kind = candidate.nameKind == 6 ? 0 : (candidate.nameKind == 4 ? 1 : 2)
        return (exact ? 0 : 10_000) + kind * 2000 + (candidate.italic == request.italic ? 0 : 1000) +
            abs(candidate.weight - request.weight)
    }
    private func fingerprint(_ row: [String: SQLValue]) -> FileFingerprint {
        FileFingerprint(size: row["size"]!.int, modified: row["mtime"]!.int, changed: row["ctime"]!.int,
                        identity: row["identity"]!.string)
    }
    private func roots() throws -> [FontRoot] {
        try store.rows("SELECT * FROM roots ORDER BY path").map {
            FontRoot(id: $0["id"]!.string, url: URL(fileURLWithPath: $0["path"]!.string),
                     available: $0["available"]!.int != 0,
                     issue: $0["issue"]?.string.isEmpty == false ? $0["issue"]!.string : nil)
        }
    }
    private func watch(_ root: FontRoot) {
        watchers.removeValue(forKey: root.id)?.stop()
        do {
            watchers[root.id] = try DirectoryWatcher(url: root.url) { [weak self] paths, rescan in
                Task { await self?.changed(root: root, paths: paths, rescan: rescan) }
            }
        } catch { progress.errors.append(error.localizedDescription) }
    }
    private func changed(root: FontRoot, paths: [String], rescan: Bool) {
        var scopes = Set<String>()
        if rescan { scopes.insert("") }
        else {
            let prefix = root.url.path + "/"
            for path in paths {
                if path == root.url.path { scopes.insert(""); continue }
                guard path.hasPrefix(prefix) else { continue }
                if FontMetadataReader.extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
                    invalidatedFiles[root.id, default: []].insert(String(path.dropFirst(prefix.count)))
                }
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                scopes.insert(parent == root.url.path ? "" : String(parent.dropFirst(prefix.count)))
            }
        }
        do {
            for scope in scopes { try mergePending(root: root.id, scope: scope, force: false) }
        } catch { progress.errors.append(error.localizedDescription) }
        debounce[root.id]?.cancel()
        debounce[root.id] = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            debounce.removeValue(forKey: root.id)
            beginWorker()
        }
    }
    private func enqueue(root: String, scope: String, force: Bool) throws {
        try mergePending(root: root, scope: scope, force: force)
        beginWorker()
    }
    private func mergePending(root: String, scope: String, force: Bool) throws {
        var jobs = pending[root] ?? [:]
        if let ancestor = jobs.keys.first(where: { $0.isEmpty || $0 == scope || scope.hasPrefix($0 + "/") }) {
            jobs[ancestor] = jobs[ancestor]! || force
        } else {
            let descendants = jobs.keys.filter { scope.isEmpty || $0.hasPrefix(scope + "/") }
            let combinedForce = force || descendants.contains { jobs[$0] == true }
            for path in descendants { jobs.removeValue(forKey: path) }
            jobs[scope] = combinedForce
        }
        pending[root] = jobs
        try store.transaction {
            try store.execute("DELETE FROM pending WHERE root_id=?", [.text(root)])
            for (path, full) in jobs {
                try store.execute("INSERT INTO pending VALUES(?,?,?)", [.text(root), .text(path), .integer(full ? 1 : 0)])
            }
        }
    }
    private func beginWorker() {
        guard worker == nil, !pending.isEmpty else { return }
        progress.scanning = true; progress.scannedFiles = 0; progress.parsedFiles = 0; progress.errors = []
        worker = Task { await drain() }
        publish()
    }
    private func drain() async {
        while let rootID = pending.keys.sorted().first,
              let scope = pending[rootID]?.keys.sorted().first {
            let force = pending[rootID]!.removeValue(forKey: scope)!
            if pending[rootID]!.isEmpty { pending.removeValue(forKey: rootID) }
            do {
                guard let record = try store.rows("SELECT * FROM roots WHERE id=?", [.text(rootID)]).first else { continue }
                var stale = false
                let rootURL = (try? URL(resolvingBookmarkData: record["bookmark"]!.data,
                                       options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale))
                    ?? URL(fileURLWithPath: record["path"]!.string)
                try store.execute("UPDATE roots SET path=? WHERE id=?", [.text(rootURL.path), .text(rootID)])
                if rootURL.path != record["path"]!.string {
                    watch(FontRoot(id: rootID, url: rootURL, available: true, issue: nil))
                }
                if stale, let bookmark = try? rootURL.bookmarkData(options: [.withSecurityScope]) {
                    try store.execute("UPDATE roots SET bookmark=? WHERE id=?", [.blob(bookmark), .text(rootID)])
                }
                progress.currentDirectory = rootURL.lastPathComponent
                // A removed subtree is reconciled through its nearest surviving parent.
                var scanScope = scope
                while !scanScope.isEmpty {
                    do {
                        let candidate = rootURL.appendingPathComponent(scanScope)
                        if try candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { break }
                    } catch {
                        let code = (error as NSError).code
                        guard [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(code) else { throw error }
                    }
                    let parent = (scanScope as NSString).deletingLastPathComponent
                    scanScope = parent == "." ? "" : parent
                }
                let condition = scanScope.isEmpty ? "" : " AND path>=? AND path<?"
                var args: [SQLValue] = [.text(rootID)]
                if !scanScope.isEmpty { args += [.text(scanScope + "/"), .text(scanScope + "0")] }
                let existing = try store.rows("SELECT * FROM files WHERE root_id=?" + condition, args)
                var known = Dictionary(uniqueKeysWithValues: existing.map {
                    ($0["path"]!.string, KnownFile(fingerprint: fingerprint($0), parserVersion: Int($0["parser_version"]!.int)))
                })
                let invalidated = (invalidatedFiles[rootID] ?? []).filter {
                    scanScope.isEmpty || $0.hasPrefix(scanScope + "/")
                }
                // Force metadata re-reading for explicit file events, even if timestamps were restored.
                for path in invalidated {
                    if let value = known[path] {
                        known[path] = KnownFile(fingerprint: value.fingerprint, parserVersion: -1)
                    }
                    invalidatedFiles[rootID]?.remove(path)
                }
                let scanKnown = known, effectiveScope = scanScope
                let result = try await Task.detached(priority: .utility) {
                    try await FontScanner.scan(root: rootURL, scope: effectiveScope, known: scanKnown, force: force) { batch in
                        try await self.apply(batch, root: rootID)
                    }
                }.value
                try store.transaction {
                    for path in result.removed {
                        try store.execute("DELETE FROM files WHERE root_id=? AND path=?", [.text(rootID), .text(path)])
                    }
                    try store.execute("UPDATE roots SET available=1,issue=? WHERE id=?",
                                      [result.complete ? .null : .text("部分文件未能读取"), .text(rootID)])
                    // A new event may have arrived while scanning; do not erase its pending job.
                    if pending[rootID]?[scope] == nil {
                        try store.execute("DELETE FROM pending WHERE root_id=? AND scope=?", [.text(rootID), .text(scope)])
                    }
                }
                progress.errors += result.errors
            } catch {
                progress.errors.append(error.localizedDescription)
                try? store.execute("UPDATE roots SET available=0,issue=? WHERE id=?",
                                   [.text(error.localizedDescription), .text(rootID)])
            }
            publish()
        }
        progress.scanning = false; progress.currentDirectory = ""
        worker = nil
        publish()
    }
    private func apply(_ batch: ScanBatch, root: String) throws {
        try store.transaction {
            for file in batch.files {
                try store.execute("""
                  INSERT INTO files(root_id,path,size,mtime,ctime,identity,parser_version,error) VALUES(?,?,?,?,?,?,?,?)
                  ON CONFLICT(root_id,path) DO UPDATE SET size=excluded.size,mtime=excluded.mtime,
                    ctime=excluded.ctime,identity=excluded.identity,parser_version=excluded.parser_version,error=excluded.error
                  """, [.text(root), .text(file.path), .integer(file.fingerprint.size), .integer(file.fingerprint.modified),
                        .integer(file.fingerprint.changed), .text(file.fingerprint.identity),
                        .integer(Int64(FontMetadataReader.version)), file.error.map(SQLValue.text) ?? .null])
                let fileID = try store.rows("SELECT id FROM files WHERE root_id=? AND path=?", [.text(root), .text(file.path)])[0]["id"]!.int
                try store.execute("DELETE FROM faces WHERE file_id=?", [.integer(fileID)])
                for face in file.faces {
                    try store.execute("INSERT INTO faces(file_id,face_index,ps_name,family,weight,italic,revision) VALUES(?,?,?,?,?,?,?)",
                                      [.integer(fileID), .integer(Int64(face.index)), .text(face.postScriptName), .text(face.family),
                                       .integer(Int64(face.weight)), .integer(face.italic ? 1 : 0), .integer(face.revision)])
                    let faceID = store.lastID
                    for name in face.names {
                        try store.execute("INSERT OR IGNORE INTO names VALUES(?,?,?,?,?)",
                                          [.integer(faceID), .integer(Int64(name.kind)), .integer(Int64(name.language)),
                                           .text(name.name), .text(FontName.key(name.name))])
                    }
                }
            }
        }
        progress.scannedFiles += batch.examined; progress.parsedFiles += batch.files.count
        if Date().timeIntervalSince(lastPublish) > 0.25 { publish() }
    }
    private func publish() {
        lastPublish = Date()
        if let value = try? snapshot() { handler?(value) }
    }
}
