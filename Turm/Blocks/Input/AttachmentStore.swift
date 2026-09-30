import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

enum AttachmentStore {
    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    static let dragTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .tiff, .png]

    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    static func pasteText(for urls: [URL]) -> String {
        urls.map { PathCompleter.escape($0.path) }.joined(separator: " ") + " "
    }

    static func urls(from pasteboard: NSPasteboard, imageOverridesText: Bool) -> [URL] {
        let files = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !files.isEmpty { return files.map(resolved) }
        if !imageOverridesText, pasteboard.string(forType: .string) != nil { return [] }
        guard let image = NSImage(pasteboard: pasteboard), let url = save(image) else { return [] }
        return [url]
    }

    /// Finder can hand over file-reference URLs (`/.file/id=...`); this turns them into real paths.
    nonisolated static func resolved(_ url: URL) -> URL {
        ((url as NSURL).filePathURL ?? url).standardizedFileURL
    }

    nonisolated static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var result: [URL] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = await fileURL(from: provider) { result.append(url) }
            } else if provider.canLoadObject(ofClass: NSImage.self),
                      let image = await load(NSImage.self, from: provider),
                      let url = save(image) {
                result.append(url)
            }
        }
        return result
    }

    nonisolated private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = item as? URL {
                    url = value
                } else if let value = item as? NSURL {
                    url = value as URL
                }
                continuation.resume(returning: url.map(resolved))
            }
        }
    }

    nonisolated private static func load<T: NSItemProviderReading>(_ type: T.Type, from provider: NSItemProvider) async -> T? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { object, _ in
                continuation.resume(returning: object as? T)
            }
        }
    }

    nonisolated static func save(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        do {
            let base = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let folder = base.appendingPathComponent("Turm/Pasted", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = folder.appendingPathComponent("Image-\(stamp)-\(UUID().uuidString.prefix(6)).png")
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    static func thumbnail(for url: URL, maxPixels: Int = 160) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}

@Observable
final class InputModel {
    var draft = ""
    private(set) var attachments: [URL] = []
    private var inserted: [URL: String] = [:]

    func attach(_ urls: [URL], paths: [URL: String] = [:]) {
        for url in urls {
            let path = paths[url] ?? url.path
            if !draft.isEmpty, !draft.hasSuffix(" "), !draft.hasSuffix("\n") { draft += " " }
            draft += PathCompleter.escape(path) + " "
            inserted[url] = path
            if AttachmentStore.isImage(url), !attachments.contains(url) { attachments.append(url) }
        }
    }

    func remove(_ url: URL) {
        attachments.removeAll { $0 == url }
        let token = PathCompleter.escape(inserted.removeValue(forKey: url) ?? url.path)
        draft = draft.replacingOccurrences(of: token + " ", with: "")
        draft = draft.replacingOccurrences(of: token, with: "")
    }

    func reset() {
        draft = ""
        attachments = []
        inserted = [:]
    }
}
