import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SubFontCore

struct MatchRow: Identifiable {
    enum State { case loaded, system, missing, failed }
    let request: FontRequest
    let state: State
    let source: String
    let note: String
    var sourceLabel: String? = nil
    var sourceContainer: URL? = nil
    var id: String { request.id }
    var title: String {
        switch state { case .loaded: "已加载"; case .system: "系统可用"; case .missing: "未找到"; case .failed: "加载失败" }
    }
    var color: Color {
        switch state { case .loaded, .system: .green; case .missing: .orange; case .failed: .red }
    }
    var symbol: String {
        switch state { case .loaded, .system: "checkmark.circle.fill"; case .missing: "questionmark.circle"; case .failed: "exclamationmark.circle" }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot = IndexSnapshot()
    @Published var rows: [MatchRow] = []
    @Published var subtitles: [URL] = []
    @Published var messages: [String] = []
    @Published var processing = false
    @Published var status = "拖入字幕或视频"
    @Published var showLibrary = false
    @Published var loadedFiles = 0
    @Published var startupError: String?
    private var index: FontIndex?
    private var session: FontSession?
    private var sourceReader: SubtitleSourceReader?
    private var pendingInputs: [URL] = []
    private var refreshRequested = false
    private var task: Task<Void, Never>?
    private var closing = false
    private var ready = false
    var readyCount: Int { rows.filter { $0.state == .loaded || $0.state == .system }.count }
    var missingCount: Int { rows.filter { $0.state == .missing || $0.state == .failed }.count }

    func start() {
        Task {
            do {
                let support = SubFontPaths.applicationSupport
                let index = try FontIndex(databaseURL: support.appendingPathComponent("index.sqlite"))
                let session = try FontSession(directory: support.appendingPathComponent("RegisteredFonts", isDirectory: true))
                self.index = index; self.session = session
                messages = await session.unloadAll()
                let sourceReader = try SubtitleSourceReader(directory: support.appendingPathComponent("EmbeddedFonts"))
                try await sourceReader.cleanUp()
                self.sourceReader = sourceReader
                await index.setHandler { [weak self] snapshot in
                    Task { @MainActor in
                        guard let self else { return }
                        let finished = self.snapshot.scanning && !snapshot.scanning
                        self.snapshot = snapshot
                        if finished && !self.subtitles.isEmpty { self.reload() }
                    }
                }
                try await index.start()
                ready = true
                process()
            } catch { startupError = error.localizedDescription; status = "SubFont 未能启动" }
        }
    }
    func open(_ urls: [URL]) {
        pendingInputs += urls.filter(\.isFileURL)
        process()
    }
    func chooseSubtitles() {
        let panel = NSOpenPanel()
        panel.title = "选择字幕、视频或文件夹"
        panel.prompt = "加载字体"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = SubtitleSourceReader.supportedExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { open(panel.urls) }
    }
    func chooseFontDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择字体文件夹"; panel.prompt = "添加字体库"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            Task {
                for url in panel.urls {
                    do { try await index?.addDirectory(url) }
                    catch { messages.append(error.localizedDescription) }
                }
            }
        }
    }
    func removeDirectory(_ id: String) {
        Task { do { try await index?.removeDirectory(id) } catch { messages.append(error.localizedDescription) } }
    }
    func refreshIndex(force: Bool = false) {
        Task { do { try await index?.refresh(force: force) } catch { messages.append(error.localizedDescription) } }
    }
    func reload() { refreshRequested = true; process() }
    func recheck() {
        Task {
            do { try await index?.refresh(); reload() }
            catch { messages.append(error.localizedDescription) }
        }
    }

    private func process() {
        guard ready, !closing, task == nil, !pendingInputs.isEmpty || refreshRequested else { return }
        processing = true
        task = Task {
            while (!pendingInputs.isEmpty || refreshRequested) && !closing && !Task.isCancelled {
                let inputs = pendingInputs
                pendingInputs.removeAll(); refreshRequested = false
                let discovery = await Task.detached(priority: .userInitiated) { Self.discover(inputs) }.value
                subtitles = Array(Set(subtitles + discovery.files)).sorted { $0.path < $1.path }
                messages = discovery.errors
                guard !subtitles.isEmpty, let index, let session, let sourceReader else { continue }
                status = snapshot.scanning ? "正在更新字体库…" : "正在读取字幕…"
                await index.waitUntilIdle()
                var requests: [String: FontRequest] = [:]
                var embedded: [String: [FontCandidate]] = [:], labels: [String: String] = [:], containers: [String: URL] = [:]
                for url in subtitles {
                    if closing || Task.isCancelled { break }
                    status = "正在读取 \(url.lastPathComponent)…"
                    do {
                        let result = try await sourceReader.read(url)
                        for request in result.requests {
                            requests[request.id] = request
                            embedded[request.id, default: []] += result.candidates(for: request)
                        }
                        for (path, label) in result.attachmentNames { labels[path] = label; containers[path] = url }
                        messages += result.warnings.map { "\(url.lastPathComponent)：\($0)" }
                    } catch is CancellationError { break }
                    catch { messages.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
                }
                if closing || Task.isCancelled { break }
                let analysis = requests.values.sorted { $0.id < $1.id }
                status = "正在加载字体…"
                do {
                    let candidates = try await index.candidates(for: analysis)
                    var output: [MatchRow] = []
                    for request in analysis {
                        if Task.isCancelled || closing { break }
                        let choices = (embedded[request.id] ?? []) + (candidates[request.id] ?? [])
                        var owned: FontCandidate?
                        if let best = choices.first, await session.owns(best), SystemFonts.contains(request) { owned = best }
                        if let owned {
                            output.append(MatchRow(request: request, state: .loaded, source: owned.url.path, note: "本次已加载"))
                        } else if SystemFonts.contains(request) {
                            output.append(MatchRow(request: request, state: .system, source: "macOS", note: "系统中已有此字体"))
                        } else if choices.isEmpty {
                            output.append(MatchRow(request: request, state: .missing, source: "", note: "请补充字体文件，索引会自动更新"))
                        } else {
                            var failure = "", loaded: FontCandidate?
                            for candidate in choices {
                                do { try await session.register(candidate, for: request); loaded = candidate; break }
                                catch { failure = error.localizedDescription }
                            }
                            if let loaded {
                                let styleFallback = loaded.italic != request.italic || abs(loaded.weight - request.weight) >= 200
                                output.append(MatchRow(request: request, state: .loaded, source: loaded.url.path,
                                    note: styleFallback ? "已加载同名字体；该字重或斜体可能由播放器合成" : "可在播放器中使用"))
                            } else {
                                output.append(MatchRow(request: request, state: .failed, source: choices[0].url.path, note: failure))
                            }
                        }
                    }
                    rows = output.map { original in
                        var row = original
                        row.sourceLabel = labels[row.source]; row.sourceContainer = containers[row.source]
                        return row
                    }
                    loadedFiles = await session.count
                    status = missingCount == 0 ? "字体已就绪" : "\(missingCount) 个字体待处理"
                } catch { messages.append(error.localizedDescription); status = "加载未完成" }
            }
            processing = false
            task = nil
        }
    }
    func shutdown() async -> [String] {
        closing = true
        task?.cancel()
        await task?.value
        var errors = await session?.unloadAll() ?? []
        do { try await sourceReader?.cleanUp() }
        catch { errors.append(error.localizedDescription) }
        return errors
    }
    nonisolated private static func discover(_ urls: [URL]) -> (files: [URL], errors: [String]) {
        var files: [URL] = [], errors: [String] = []
        for url in urls {
            do {
                if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
                    while let child = walker?.nextObject() as? URL {
                        let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        if values.isSymbolicLink == true { walker?.skipDescendants(); continue }
                        if values.isRegularFile == true && SubtitleSourceReader.supportedExtensions.contains(child.pathExtension.lowercased()) { files.append(child) }
                    }
                } else if SubtitleSourceReader.supportedExtensions.contains(url.pathExtension.lowercased()) { files.append(url) }
                else { errors.append("\(url.lastPathComponent)：请选择 ASS/SSA 字幕或 MKV、MP4、MOV 视频") }
            } catch { errors.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        return (files, errors)
    }
}
