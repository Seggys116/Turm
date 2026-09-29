import Darwin
import Foundation

@_silgen_name("shm_open")
private func sharedMemoryOpen(_ name: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32

struct KittyFailure: Error, Equatable {
    let code: String
    let message: String
}

struct KittyLoadState {
    var received = 0
    var compressed = Data()
    var direct = Data()
    var fileData = Data()
    var inflated: Data?
    var available = 0
    var openedPath: String?
    var openedShared = false
    var firstBytes: [UInt8] = []
}

enum KittyLoadCheck {
    static let maxDimension = 10_000
    static let maxData = 400_000_000
    static let fileFailure = KittyFailure(code: "EBADF", message: "Failed to read image file")

    static func format(_ command: KittyCommand) -> Int {
        command.format ?? 32
    }

    static func isFile(_ command: KittyCommand) -> Bool {
        guard let medium = command.medium else { return false }
        return medium == "f" || medium == "t" || medium == "s"
    }

    static func dataSize(_ command: KittyCommand) -> Int {
        let fmt = format(command)
        if fmt == 100 { return command.dataSize > 0 ? command.dataSize : 100 * 1024 }
        return (command.stateValue ?? 0) * (command.loopValue ?? 0) * (fmt / 8)
    }

    static func initialize(_ command: KittyCommand) -> KittyFailure? {
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

    static func accept(
        _ state: inout KittyLoadState, chunk: ArraySlice<UInt8>, command: KittyCommand, more: Bool
    ) -> KittyFailure? {
        let decoded = Data(base64Encoded: Data(chunk), options: .ignoreUnknownCharacters) ?? Data()
        switch command.medium ?? "d" {
        case "d":
            state.received += decoded.count
            let capacity = format(command) == 100 ? maxData : dataSize(command) + (command.compression != nil ? 1024 : 10)
            if state.received > capacity { return KittyFailure(code: "EFBIG", message: "Too much data") }
            if command.compression == "z" {
                state.compressed.append(decoded)
            } else if format(command) == 100 {
                state.direct.append(decoded)
            }
            if more { return nil }
        case "f", "t", "s":
            if decoded.count > 2048 { return KittyFailure(code: "EINVAL", message: "Filename too long") }
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

    private static func finish(_ state: inout KittyLoadState, _ command: KittyCommand) -> KittyFailure? {
        if let compression = command.compression, compression != "z" {
            return KittyFailure(code: "EINVAL", message: "Unknown image compression: \(compression)")
        }
        var used = state.received
        if command.compression == "z" {
            switch KittyInflate.inflate(isFile(command) ? state.fileData : state.compressed, capacity: dataSize(command)) {
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

    static func discardTransient(_ state: KittyLoadState, _ command: KittyCommand) {
        guard let path = state.openedPath else { return }
        if command.medium == "t", path.contains("tty-graphics-protocol") {
            unlink(path)
        } else if command.medium == "s" {
            shm_unlink(path)
        }
    }
}
