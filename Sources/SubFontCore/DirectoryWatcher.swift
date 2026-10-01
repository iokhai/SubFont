import Foundation
import CoreServices

final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "SubFont.directory-events", qos: .utility)

    private final class Callback: @unchecked Sendable {
        let changed: @Sendable ([String], Bool) -> Void
        init(_ changed: @escaping @Sendable ([String], Bool) -> Void) { self.changed = changed }
    }

    init(url: URL, changed: @escaping @Sendable ([String], Bool) -> Void) throws {
        let box = Unmanaged.passRetained(Callback(changed))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil,
            release: { pointer in if let pointer { Unmanaged<Callback>.fromOpaque(pointer).release() } },
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes |
                                            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(nil, { _, info, count, pathsPointer, flags, _ in
            guard let info else { return }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(pathsPointer, to: CFArray.self) as! [String]
            var rescan = false
            for i in 0..<count {
                if flags[i] & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
                                    kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged |
                                    kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 {
                    rescan = true
                }
            }
            callback.changed(paths, rescan)
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.6, flags)
        guard let stream else {
            box.release()
            throw SubFontError.message("无法监听字体目录")
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil
            throw SubFontError.message("无法启动字体目录监听")
        }
    }
    func stop() {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
    deinit { stop() }
}
