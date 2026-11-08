import Darwin
import Foundation

@_silgen_name("shm_open")
private func sharedMemoryOpen(_ name: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32

public struct KittyFailure: Error, Equatable {
    public let code: String
    public let message: String
}

public struct KittyLoadState {
    public init() {}
    public var received = 0
    var compressed = Data()
    var direct = Data()
    var fileData = Data()
    public var inflated: Data?
    var available = 0
    public var openedPath: String?
    var openedShared = false
    public var firstBytes: [UInt8] = []
}

public enum KittyLoadCheck {
    static let maxDimension = 10_000
    static let maxData = 400_000_000
    static let fileFailure = KittyFailure(code: "EBADF", message: "Failed to read image file")

    public static func format(_ command: KittyCommand) -> Int {
        command.format ?? 32
    }

    public static func isFile(_ command: KittyCommand) -> Bool {
        guard let medium = command.medium else { return false }
        return medium == "f" || medium == "t" || medium == "s"
    }

    public static func dataSize(_ command: KittyCommand) -> Int {
        let fmt = format(command)
        if fmt == 100 { return command.dataSize > 0 ? command.dataSize : 100 * 1024 }
        return (command.stateValue ?? 0) * (command.loopValue ?? 0) * (fmt / 8)
    }

    public static func initialize(_ command: KittyCommand) -> KittyFailure? {
        let width = command.stateValue ?? 0
        let height = command.loopValue ?? 0
        if width > maxDimension || height > maxDimension {
            return KittyFailure(code: "EINVAL", message: "Image too large, width or height greater than \(maxDimension)")
        }
        switch format(command) {
        case 100:
            if command.dataSize > maxData { return KittyFailure(code: "EINVAL", message: "PNG data size too large") }
        case 24, 32:
            if width * height == 0 { return KittyFailure(code: "EINVAL", message: "Zero width/height not allowed") }
        default:
            return KittyFailure(code: "EINVAL", message: "Unknown image format: \(format(command))")
        }
        return nil
    }

    public static func accept(
        _ state: inout KittyLoadState, chunk: ArraySlice<UInt8>, command: KittyCommand, more: Bool,
        allowsLocalMedia: Bool = true
    ) -> KittyFailure? {
        let decoded = Data(base64Encoded: Data(chunk), options: .ignoreUnknownCharacters) ?? Data()
        switch command.medium ?? "d" {
        case "d":
            state.received += decoded.count
            let capacity = format(command) == 100 ? maxData : dataSize(command) + (command.compression != nil ? 1024 : 10)
            if state.received > capacity { return KittyFailure(code: "EFBIG", message: "Too much data") }
            if command.compression == "z" {
                state.compressed.append(decoded)
            } else {
                state.direct.append(decoded)
            }
            if more { return nil }
        case "f", "t", "s":
            if decoded.count > 2048 { return KittyFailure(code: "EINVAL", message: "Filename too long") }
            guard allowsLocalMedia else { return fileFailure }
            if let failure = open(String(decoding: decoded, as: UTF8.self), command, &state) { return failure }
        default:
            return KittyFailure(code: "EINVAL", message: "Unknown transmission type: \(command.medium ?? "d")")
        }
        return finish(&state, command)
    }

    private static func open(_ name: String, _ command: KittyCommand, _ state: inout KittyLoadState) -> KittyFailure? {
        let shared = command.medium == "s"
        let descriptor: Int32
        if shared {
            guard name.hasPrefix("/") else { return fileFailure }
            descriptor = name.withCString { sharedMemoryOpen($0, O_RDONLY, 0) }
        } else {
            guard KittyFilePolicy.mayRead(name) else { return fileFailure }
            descriptor = name.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK) }
        }
        guard descriptor >= 0 else { return fileFailure }
        defer { close(descriptor) }
        state.openedPath = name
        state.openedShared = shared
        var info = stat()
        guard fstat(descriptor, &info) == 0, shared || (info.st_mode & S_IFMT) == S_IFREG else { return fileFailure }
        let fileSize = Int(info.st_size)
        let offset = command.dataOffset
        state.available = offset < fileSize ? fileSize - offset : 0
        let limit = command.compression != nil || format(command) == 100 ? maxData : dataSize(command)
        let wanted = min(command.dataSize > 0 ? command.dataSize : state.available, limit)
        state.received = min(wanted, state.available)
        guard command.compression != nil || format(command) == 100, state.received > 0 else { return nil }
        guard let map = mmap(nil, fileSize, PROT_READ, MAP_PRIVATE, descriptor, 0), map != MAP_FAILED else {
            return fileFailure
        }
        defer { munmap(map, fileSize) }
        state.fileData = Data(bytes: map.advanced(by: offset), count: state.received)
        return nil
    }

    public static func sharedSlice(_ name: String, offset: Int, count: Int) -> Data? {
        let descriptor = name.withCString { sharedMemoryOpen($0, O_RDONLY, 0) }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, offset >= 0, count > 0, offset + count <= Int(info.st_size) else { return nil }
        guard let map = mmap(nil, Int(info.st_size), PROT_READ, MAP_SHARED, descriptor, 0), map != MAP_FAILED else { return nil }
        defer { munmap(map, Int(info.st_size)) }
        return Data(bytes: map.advanced(by: offset), count: count)
    }

    private static func finish(_ state: inout KittyLoadState, _ command: KittyCommand) -> KittyFailure? {
        if let compression = command.compression, compression != "z" {
            return KittyFailure(code: "EINVAL", message: "Unknown image compression: \(compression)")
        }
        var used = state.received
        if command.compression == "z" {
            let png = format(command) == 100
            let source = isFile(command) ? state.fileData : state.compressed
            switch KittyInflate.inflate(source, capacity: png ? maxData : dataSize(command), exact: !png) {
            case .success(let data):
                state.inflated = data
                used = data.count
            case .failure(let failure):
                return failure
            }
        }
        if format(command) == 100 {
            let png = state.inflated ?? (isFile(command) ? state.fileData : state.direct)
            return KittyPNGCheck.validate([UInt8](png), maxDimension: maxDimension)
        }
        guard used >= dataSize(command) else {
            if isFile(command) { return fileFailure }
            return KittyFailure(code: "ENODATA", message: "Insufficient image data: \(used) < \(dataSize(command))")
        }
        return nil
    }

    public static func bytes(_ state: KittyLoadState, command: KittyCommand) -> Data? {
        if let inflated = state.inflated { return inflated }
        guard isFile(command) else { return state.direct.isEmpty ? nil : state.direct }
        if !state.fileData.isEmpty { return state.fileData }
        guard let path = state.openedPath, state.received > 0 else { return nil }
        if state.openedShared {
            return sharedSlice(path, offset: command.dataOffset, count: state.received)
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(command.dataOffset))) != nil,
              let data = try? handle.read(upToCount: state.received), data.count == state.received else { return nil }
        return data
    }

    public static func discardTransient(_ state: KittyLoadState, _ command: KittyCommand) {
        guard let path = state.openedPath else { return }
        if command.medium == "t", KittyFilePolicy.mayDelete(path) {
            unlink(path)
        } else if command.medium == "s" {
            shm_unlink(path)
        }
    }
}
