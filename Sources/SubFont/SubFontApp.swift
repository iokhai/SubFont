import AppKit
import SwiftUI

@main
struct SubFontApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    private let model = AppModel()
    private var window: NSWindow?
    private var terminating = false
    private var mountObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "SubFont"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 400)
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        let toolbar = NSToolbar(identifier: "SubFont.Toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("SubFont.Main")
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.model.refreshIndex() } }
        model.start()
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if !arguments.isEmpty { model.open(arguments.map { URL(fileURLWithPath: $0) }) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        model.open(urls); showWindow()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    @objc(loadSubtitleFonts:userData:error:)
    func loadSubtitleFonts(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        if urls.isEmpty {
            error.pointee = "请选择字幕、视频或文件夹。" as NSString
            return
        }
        model.open(urls); showWindow()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            let errors = await model.shutdown()
            if !errors.isEmpty {
                let alert = NSAlert()
                alert.messageText = "部分字体未能卸载"
                alert.informativeText = "SubFont 已保留清理记录，下次启动会重试。\n" + errors.prefix(3).joined(separator: "\n")
                alert.addButton(withTitle: "退出")
                alert.runModal()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    private func showWindow() {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    @objc private func openSubtitles() { model.chooseSubtitles() }
    @objc private func showLibrary() { model.showLibrary = true; showWindow() }
    @objc private func recheckFonts() { model.recheck() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(recheckFonts) { return !model.subtitles.isEmpty && !model.processing }
        return true
    }
    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "关于 SubFont", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let library = app.addItem(withTitle: "字体库…", action: #selector(showLibrary), keyEquivalent: ","); library.target = self
        let services = NSMenu()
        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        servicesItem.submenu = services; app.addItem(servicesItem); NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏 SubFont", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "卸载字体并退出 SubFont", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app; main.addItem(appItem)
        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        let file = NSMenu(title: "文件")
        let open = file.addItem(withTitle: "打开字幕或视频…", action: #selector(openSubtitles), keyEquivalent: "o"); open.target = self
        let recheck = file.addItem(withTitle: "重新检查字体", action: #selector(recheckFonts), keyEquivalent: "r"); recheck.target = self
        file.addItem(.separator())
        file.addItem(withTitle: "卸载并关闭", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "w")
        fileItem.submenu = file; main.addItem(fileItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; main.addItem(editItem)
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windows = NSMenu(title: "窗口")
        windows.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windows; main.addItem(windowItem)
        NSApp.windowsMenu = windows; NSApp.mainMenu = main
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .init("openSubtitles"), .init("fontLibrary")]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .init("fontLibrary"), .init("openSubtitles")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier.rawValue == "openSubtitles" {
            item.label = "打开文件"; item.toolTip = "打开字幕、视频或文件夹"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: item.label)
            item.action = #selector(openSubtitles)
        } else {
            item.label = "字体库"; item.toolTip = "管理字体文件夹"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: item.label)
            item.action = #selector(showLibrary)
        }
        item.target = self
        return item
    }
}
