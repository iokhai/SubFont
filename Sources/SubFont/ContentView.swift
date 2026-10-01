import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SubFontCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var targeted = false
    @State private var showMessages = false

    private var messages: [String] {
        var seen = Set<String>()
        let failures = model.rows.filter { $0.state == .failed }.map { "\($0.request.name)：\($0.note)" }
        return (model.messages + [model.startupError].compactMap { $0 } + failures)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    private var subtitleTitle: String {
        guard let first = model.subtitles.first else { return "" }
        return model.subtitles.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) 等 \(model.subtitles.count) 个文件"
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.rows.isEmpty {
                HStack(spacing: 12) {
                    if model.processing {
                        ProgressView().controlSize(.small).frame(width: 28)
                    } else {
                        Image(systemName: model.missingCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(model.missingCount == 0 ? Color.green : .orange)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.status).font(.title3.weight(.semibold))
                        Text(subtitleTitle).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(model.subtitles.map(\.path).joined(separator: "\n"))
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 24).padding(.vertical, 20)

                Table(model.rows) {
                    TableColumn("字体") { row in
                        HStack(spacing: 8) {
                            Text(row.request.name).fontWeight(.medium)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            if row.request.weight != 400 || row.request.italic {
                                Text(row.request.styleDescription).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(details(for: row))
                        .contextMenu {
                            Button("复制字体名称") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(row.request.name, forType: .string)
                            }
                            if row.source.hasPrefix("/") {
                                Button("在 Finder 中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([row.sourceContainer ?? URL(fileURLWithPath: row.source)])
                                }
                            }
                        }
                    }.width(min: 240, ideal: 400)
                    TableColumn("状态") { row in
                        Label(row.title, systemImage: row.symbol)
                            .foregroundStyle(row.color)
                            .help(details(for: row))
                    }.width(110)
                }.tableStyle(.inset)
            } else {
                VStack(spacing: 12) {
                    if model.processing {
                        ProgressView().controlSize(.large).padding(.bottom, 8)
                    } else {
                        Image(systemName: model.subtitles.isEmpty ? "captions.bubble" : "text.magnifyingglass")
                            .font(.system(size: 46, weight: .light)).foregroundStyle(.tertiary)
                            .padding(.bottom, 4)
                    }
                    Text(model.processing ? "正在读取字幕…" : model.subtitles.isEmpty ? "拖入字幕或视频" : "未发现字体需求")
                        .font(.title2.weight(.medium))
                    if model.subtitles.isEmpty && !model.processing {
                        Text("ASS / SSA · MKV · MP4 / MOV").font(.callout).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if model.snapshot.scanning || !messages.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if model.snapshot.scanning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text("正在更新字体库…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !messages.isEmpty {
                        DisclosureGroup(isExpanded: $showMessages) {
                            ScrollView {
                                Text(messages.joined(separator: "\n"))
                                    .font(.caption).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 90).padding(.top, 6)
                        } label: {
                            Label("\(messages.count) 条提示", systemImage: "exclamationmark.bubble")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.horizontal, 24).padding(.vertical, 12)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .background(.background)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else { url = nil }
                    if let url { Task { @MainActor in model.open([url]) } }
                }
            }
            return !providers.isEmpty
        }
        .sheet(isPresented: $model.showLibrary) { LibraryView(model: model) }
        .onChange(of: model.processing) { _, processing in
            if !processing && model.rows.isEmpty && !messages.isEmpty { showMessages = true }
        }
    }

    private func details(for row: MatchRow) -> String {
        [row.sourceLabel ?? row.source, row.note].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("字体库").font(.title2.weight(.semibold))
                Spacer()
                if !model.snapshot.roots.isEmpty {
                    Button(action: model.chooseFontDirectory) {
                        Image(systemName: "plus").frame(width: 18, height: 18)
                    }.buttonStyle(.glass).help("添加字体文件夹").accessibilityLabel("添加字体文件夹")
                    Menu {
                        Button("检查更新") { model.refreshIndex() }
                        Button("重建索引") { model.refreshIndex(force: true) }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 18, height: 18)
                    }.menuStyle(.borderlessButton).fixedSize()
                        .help("字体库操作").accessibilityLabel("字体库操作")
                        .disabled(model.snapshot.scanning)
                }
            }.padding(24)

            if model.snapshot.roots.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
                    Button("添加字体文件夹", action: model.chooseFontDirectory).buttonStyle(.glassProminent)
                }.frame(maxWidth: .infinity).frame(height: 180)
            } else {
                List(model.snapshot.roots) { root in
                    HStack(spacing: 12) {
                        Image(systemName: root.available ? "folder.fill" : "externaldrive.badge.exclamationmark")
                            .font(.title2).foregroundStyle(root.available ? Color.accentColor : .orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(root.url.lastPathComponent).fontWeight(.medium)
                            Text(root.url.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            if let issue = root.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        Button { model.removeDirectory(root.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("从字体库移除，不删除字体文件")
                            .accessibilityLabel("移除 \(root.url.lastPathComponent)")
                            .disabled(model.snapshot.scanning)
                    }.padding(.vertical, 6)
                }.listStyle(.inset).frame(height: 200)
            }

            if !model.snapshot.errors.isEmpty {
                DisclosureGroup("\(model.snapshot.errors.count) 个读取问题") {
                    ScrollView {
                        Text(model.snapshot.errors.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 90).padding(.top, 6)
                }.font(.callout).padding(.horizontal, 24).padding(.vertical, 12)
            }

            Divider()
            HStack(spacing: 8) {
                if model.snapshot.scanning {
                    ProgressView().controlSize(.mini)
                    Text("已检查 \(model.snapshot.scannedFiles) 个文件")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !model.snapshot.roots.isEmpty {
                    Text("\(model.snapshot.faces) 个字体 · 自动更新")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.glass)
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: 540)
    }
}
