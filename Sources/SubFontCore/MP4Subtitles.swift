import Foundation
import AVFoundation
import CoreMedia

/// AVFoundation demuxes only subtitle tracks, including fragmented MP4 files.
/// Font tables and defaults: CMTextFormatDescription extensions in CoreMedia.
enum MP4Subtitles {
    static func read(_ url: URL) async throws -> MediaContents {
        let asset = AVURLAsset(url: url)
        var tracks = try await asset.loadTracks(withMediaType: .subtitle)
        tracks += try await asset.loadTracks(withMediaType: .text)
        tracks += try await asset.loadTracks(withMediaType: .closedCaption)
        try Task.checkCancellation()
        guard !tracks.isEmpty else { return MediaContents(warnings: ["视频没有内嵌字幕轨"]) }
        guard tracks.count <= 256 else { throw SubFontError.message("视频中的字幕轨过多") }
        var requests: [String: FontRequest] = [:], warnings: [String] = [], total = 0
        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            let label = "字幕轨 \(index + 1)"
            do {
                let formats = try await track.load(.formatDescriptions)
                guard formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kCMTextFormatType_3GText }) else {
                    warnings.append("\(label)：仅支持 tx3g 文本字幕；该轨道没有可读取的字体声明")
                    continue
                }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { throw MediaBytes.invalid }
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? MediaBytes.invalid }
                defer { reader.cancelReading() }
                while let buffer = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    // AVFoundation also emits edit-boundary/drain markers without media samples.
                    if CMSampleBufferGetNumSamples(buffer) == 0 { continue }
                    try autoreleasepool {
                        guard let description = CMSampleBufferGetFormatDescription(buffer),
                              CMFormatDescriptionGetMediaSubType(description) == kCMTextFormatType_3GText,
                              let block = CMSampleBufferGetDataBuffer(buffer) else { throw MediaBytes.invalid }
                        let length = CMBlockBufferGetDataLength(block)
                        if length == 0 { return }
                        guard length <= 4 * 1024 * 1024, total <= 64 * 1024 * 1024 - length else {
                            throw SubFontError.message("内嵌字幕超过读取限制")
                        }
                        total += length
                        var data = Data(count: length)
                        let status = data.withUnsafeMutableBytes {
                            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
                        }
                        guard status == kCMBlockBufferNoErr else { throw MediaBytes.invalid }
                        var offset = 0
                        for sample in 0..<CMSampleBufferGetNumSamples(buffer) {
                            let size = CMSampleBufferGetSampleSize(buffer, at: sample)
                            guard size >= 0, size <= data.count - offset else { throw MediaBytes.invalid }
                            for request in try parse(data.subdata(in: offset..<offset + size), description: description) {
                                requests[request.id] = request
                            }
                            offset += size
                        }
                    }
                }
                if reader.status == .failed { throw reader.error ?? MediaBytes.invalid }
            } catch is CancellationError { throw CancellationError() }
            catch { warnings.append("\(label)：解析不完整：\(error.localizedDescription)") }
        }
        if requests.isEmpty && warnings.isEmpty { warnings.append("内嵌字幕没有可解析的文字") }
        // Counts subtitle bytes processed, not AVFoundation's internal metadata I/O.
        return MediaContents(requests: requests.values.sorted { $0.id < $1.id }, warnings: warnings, bytesRead: total)
    }

    private static func parse(_ data: Data, description: CMFormatDescription) throws -> [FontRequest] {
        var bytes = MediaBytes(data)
        let length = Int(try bytes.uint(2))
        let text = try bytes.data(length)
        guard length > 0 else { return [] }
        let decoded: String?
        if text.starts(with: [0xFE, 0xFF]) { decoded = String(data: text.dropFirst(2), encoding: .utf16BigEndian) }
        else if text.starts(with: [0xFF, 0xFE]) { decoded = String(data: text.dropFirst(2), encoding: .utf16LittleEndian) }
        else { decoded = String(data: text, encoding: .utf8) }
        guard let decoded else { throw MediaBytes.invalid }
        let characterCount = decoded.unicodeScalars.count
        guard characterCount > 0 else { return [] }
        guard let rawExtensions = CMFormatDescriptionGetExtensions(description) else { throw MediaBytes.invalid }
        let extensions = rawExtensions as NSDictionary
        guard let fonts = extensions[kCMTextFormatDescriptionExtension_FontTable] as? [String: String],
              let defaults = extensions[kCMTextFormatDescriptionExtension_DefaultStyle] as? NSDictionary,
              let defaultID = defaults[kCMTextFormatDescriptionStyle_Font] as? NSNumber else { throw MediaBytes.invalid }
        let defaultFace = (defaults[kCMTextFormatDescriptionStyle_FontFace] as? NSNumber)?.intValue ?? 0
        func request(_ id: Int, _ face: Int) throws -> FontRequest {
            guard let name = fonts[String(id)], !name.isEmpty else { throw MediaBytes.invalid }
            return FontRequest(name: name, weight: face & 1 != 0 ? 700 : 400, italic: face & 2 != 0)
        }
        var requests: [FontRequest] = [], styled: [Range<Int>] = []
        while bytes.remaining > 0 {
            let size = Int(try bytes.uint(4))
            let type = String(decoding: try bytes.data(4), as: UTF8.self)
            guard size >= 8, size - 8 <= bytes.remaining else { throw MediaBytes.invalid }
            var atom = MediaBytes(try bytes.data(size - 8))
            if type == "styl" {
                let count = Int(try atom.uint(2))
                guard count <= 4096 else { throw MediaBytes.invalid }
                for _ in 0..<count {
                    let start = Int(try atom.uint(2)), end = Int(try atom.uint(2))
                    let font = Int(try atom.uint(2)), face = Int(try atom.uint(1))
                    _ = try atom.data(5) // point size and RGBA color
                    guard start <= end, end <= characterCount else { throw MediaBytes.invalid }
                    if start < end { styled.append(start..<end); requests.append(try request(font, face)) }
                }
                guard atom.remaining == 0 else { throw MediaBytes.invalid }
            }
        }
        var covered = 0, hasGap = false
        for range in styled.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if range.lowerBound > covered { hasGap = true }
            covered = max(covered, range.upperBound)
        }
        if hasGap || covered < characterCount { requests.append(try request(defaultID.intValue, defaultFace)) }
        return requests
    }
}
