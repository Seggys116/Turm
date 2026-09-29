import AppKit
import CoreGraphics
import Foundation
import SwiftTerm

enum KittyLanding {
    case place
    case harvest
    case frame
    case discard
}

enum KittyAfter {
    case none
    case put
    case virtual
}

struct KittyJob {
    var command: KittyCommand
    var landing: KittyLanding
    var after = KittyAfter.none
    var silent = false
    var load = KittyLoadState()
}

private enum Admission {
    case feed([UInt8])
    case hold
    case reject(KittyFailure)
}

extension BlockEmulator {
    static let scratchImageID: UInt32 = 4_294_967_000
    private static let displayKeys: Set<Character> = ["x", "y", "w", "h", "c", "r", "z", "X", "Y", "U", "P", "Q", "H", "V", "p"]

    var cursorRow: Int {
        terminal.buffer.yDisp + terminal.buffer.y + terminal.buffer.totalLinesTrimmed
    }

    var virtualKeys: Set<KittyKey> {
        Set(virtualPlacements.map { KittyKey(imageID: $0.kittyID ?? 0, placementID: $0.placementID ?? 0) })
    }

    func emit(_ control: String, _ message: String, quiet: Int) {
        guard quiet == 0 || (quiet == 1 && message != "OK") else { return }
        onResponse(Array("\u{1B}_G\(control);\(message)\u{1B}\\".utf8)[...])
    }

    private func identity(_ command: KittyCommand, frame: Int? = nil) -> String {
        var parts: [String] = []
        if let id = command.imageID { parts.append("i=\(id)") }
        if let number = command.imageNumber { parts.append("I=\(number)") }
        if let placement = command.placementID { parts.append("p=\(placement)") }
        if let frame, frame > 0, command.action == "f" || command.action == "a" { parts.append("r=\(frame)") }
        return parts.joined(separator: ",")
    }

    private func fail(_ failure: (code: String, message: String), _ command: KittyCommand, frame: Int? = nil) {
        emit(identity(command, frame: frame ?? command.rows), "\(failure.code):\(failure.message)", quiet: command.quiet)
    }

    private func missingImage(_ command: KittyCommand) {
        let message = "Animation command refers to non-existent image with id: \(command.imageID ?? 0) and number: \(command.imageNumber ?? 0)"
        fail(("ENOENT", message), command)
    }

    func deliver(_ data: ArraySlice<UInt8>) {
        let reply = KittyReply.parse(data)
        guard let out = replyFilter.filtered(data, reply: reply) else { return }
        onResponse(out)
    }

    private func rewritten(
        _ apc: ArraySlice<UInt8>, _ command: KittyCommand,
        dropping keys: Set<Character> = [], setting values: [(Character, String)] = []
    ) -> [UInt8] {
        var values = values
        if command.quiet != 0 { values.append(("q", "0")) }
        guard !keys.isEmpty || !values.isEmpty else { return Array(apc) }
        return KittyGraphicsScanner.rewrite(apc, dropping: keys, setting: values)
    }

    private func run(_ bytes: [UInt8], filter: KittyReplyFilter) {
        replyFilter = filter
        terminal.feed(byteArray: bytes)
        replyFilter = KittyReplyFilter()
    }

    private func filter(for job: KittyJob) -> KittyReplyFilter {
        var filter = KittyReplyFilter(quiet: job.silent ? 2 : job.command.quiet)
        filter.dropsOK = job.landing == .frame || job.after == .put
        filter.fileMedium = KittyLoadCheck.isFile(job.command)
        filter.png = KittyLoadCheck.format(job.command) == 100
        if job.landing == .frame {
            let original = job.command.imageID.map { "i=\($0)" } ?? job.command.imageNumber.map { "I=\($0)" } ?? ""
            filter.alias = (Self.scratchImageID, original)
        } else if let id = job.command.imageID {
            filter.alias = (engineID(id), "i=\(id)" + (job.command.imageNumber.map { ",I=\($0)" } ?? ""))
        }
        return filter
    }

    func feedGraphics(_ apc: ArraySlice<UInt8>, _ command: KittyCommand) {
        guard let action = command.action else {
            continueChunk(Array(apc), command)
            return
        }
        if command.imageID != nil, command.imageNumber != nil, "acdfp".contains(action) {
            fail(("EINVAL", "Must not specify both image id and image number"), command)
            if action == "f", command.more { start([], KittyJob(command: command, landing: .discard)) }
            return
        }
        switch action {
        case "d": deleteImages(apc, command)
        case "a": controlAnimation(command)
        case "c": composeFrames(command)
        case "f": beginFrame(apc, command)
        case "t", "T": beginTransmit(apc, command)
        case "p": beginPut(apc, command)
        default: run(rewritten(apc, command), filter: KittyReplyFilter(quiet: command.quiet))
        }
    }

    private func admit(_ job: inout KittyJob, _ bytes: [UInt8], first: Bool, more: Bool) -> Admission {
        guard job.landing != .discard, job.command.transmits || job.command.action == "f" else { return .feed(bytes) }
        if first {
            if let failure = KittyLoadCheck.initialize(job.command) { return .reject(failure) }
            job.load.firstBytes = bytes
        }
        let payload = KittyGraphicsScanner.payload(of: bytes[...])
        if let failure = KittyLoadCheck.accept(&job.load, chunk: payload, command: job.command, more: more) {
            return .reject(failure)
        }
        if !more, job.command.compression == nil, KittyLoadCheck.format(job.command) != 100, (job.command.medium ?? "d") == "d" {
            let excess = job.load.received - KittyLoadCheck.dataSize(job.command)
            var decoded = Data(base64Encoded: Data(payload), options: .ignoreUnknownCharacters) ?? Data()
            if excess > 0, decoded.count >= excess {
                decoded.removeLast(excess)
                return .feed(KittyGraphicsScanner.replacingPayload(bytes, with: Array(decoded.base64EncodedString().utf8)))
            }
        }
        guard job.command.compression == "z" else { return .feed(bytes) }
        if more { return .hold }
        guard let inflated = job.load.inflated else { return .feed(bytes) }
        let control = KittyGraphicsScanner.rewrite(job.load.firstBytes[...], dropping: ["o", "m", "t", "S", "O"], setting: [])
        return .feed(KittyGraphicsScanner.replacingPayload(control, with: Array(inflated.base64EncodedString().utf8)))
    }

    private func reject(_ failure: KittyFailure, _ job: KittyJob, more: Bool) {
        if !job.silent { fail((failure.code, failure.message), job.command) }
        KittyLoadCheck.discardTransient(job.load, job.command)
        if job.command.transmits, let id = job.command.imageID {
            evict(id)
            unloaded.insert(id)
        }
        chunked = more ? KittyJob(command: job.command, landing: .discard) : nil
    }

    private func continueChunk(_ bytes: [UInt8], _ command: KittyCommand) {
        guard var job = chunked else {
            terminal.feed(byteArray: bytes)
            return
        }
        if job.landing == .discard {
            if !command.more { chunked = nil }
            return
        }
        switch admit(&job, bytes, first: false, more: command.more) {
        case .reject(let failure):
            reject(failure, job, more: command.more)
        case .hold:
            chunked = job
        case .feed(let out):
            if command.more {
                chunked = job
                terminal.feed(byteArray: out)
            } else {
                chunked = nil
                execute(forFeeding(out, job), job)
                release(job)
            }
        }
    }

    private func release(_ job: KittyJob) {
        KittyLoadCheck.discardTransient(job.load, job.command)
    }

    private func forFeeding(_ bytes: [UInt8], _ job: KittyJob) -> [UInt8] {
        guard job.command.medium == "t", job.command.compression == nil else { return bytes }
        return KittyGraphicsScanner.rewrite(bytes[...], dropping: [], setting: [("t", "f")])
    }

    private func start(_ bytes: [UInt8], _ job: KittyJob) {
        var job = job
        if job.landing == .discard {
            if job.command.more { chunked = job }
            return
        }
        switch admit(&job, bytes, first: true, more: job.command.more) {
        case .reject(let failure):
            reject(failure, job, more: job.command.more)
        case .hold:
            chunked = job
        case .feed(let out):
            let engine = toEngine(out, &job)
            if job.command.more {
                chunked = job
                terminal.feed(byteArray: engine)
            } else {
                execute(forFeeding(engine, job), job)
                release(job)
            }
        }
    }

    private func beginTransmit(_ original: ArraySlice<UInt8>, _ source: KittyCommand) {
        var command = source
        var apc = original
        var silent = false
        if command.action == "T", command.isCropped, !command.virtual, command.imageID == nil, command.imageNumber == nil {
            command.imageID = nextInternalID
            nextInternalID += 1
            silent = true
            apc = KittyGraphicsScanner.rewrite(original, dropping: [], setting: [("i", "\(command.imageID ?? 0)")])[...]
        }
        let addressable = command.imageID != nil || command.imageNumber != nil
        let harvest = { self.rewritten(apc, command, dropping: Self.displayKeys, setting: [("a", "T"), ("C", "1")]) }
        var job = KittyJob(command: command, landing: .place, silent: silent)
        let bytes: [UInt8]
        if command.action == "t" {
            job.landing = .harvest
            bytes = harvest()
        } else if command.virtual, addressable {
            job.landing = .harvest
            job.after = .virtual
            bytes = harvest()
        } else if command.isCropped, addressable {
            job.landing = .harvest
            job.after = .put
            bytes = harvest()
        } else if command.isRelative {
            if let failure = parentFailure(command) {
                fail(failure, command)
                job.landing = .harvest
                bytes = harvest()
            } else {
                bytes = rewritten(apc, command, dropping: ["P", "Q", "H", "V"], setting: [("C", "1")])
            }
        } else {
            bytes = rewritten(apc, command)
        }
        start(bytes, job)
    }

    private func admitPut(_ command: KittyCommand) -> Bool {
        guard command.imageID != nil || command.imageNumber != nil else { return false }
        let id = command.imageID ?? command.imageNumber.flatMap { imageNumbers[$0] }
        if let id, sources[id] != nil {
            accessClock += 1
            sources[id]?.touched = accessClock
            return true
        }
        if let id, unloaded.contains(id) {
            fail(("ENOENT", "Put command refers to image with id: \(id) that could not load its data"), command)
        } else {
            let message = "Put command refers to non-existent image with id: \(command.imageID ?? 0) and number: \(command.imageNumber ?? 0)"
            fail(("ENOENT", message), command)
        }
        return false
    }

    private func beginPut(_ apc: ArraySlice<UInt8>, _ command: KittyCommand) {
        guard admitPut(command) else { return }
        if command.virtual {
            placeVirtual(command)
            return
        }
        let bytes: [UInt8]
        if command.isRelative {
            if let failure = parentFailure(command) {
                fail(failure, command)
                return
            }
            bytes = rewritten(apc, command, dropping: ["P", "Q", "H", "V"], setting: [("C", "1")])
        } else {
            bytes = rewritten(apc, command)
        }
        var job = KittyJob(command: command, landing: .place)
        execute(toEngine(bytes, &job), job)
    }

    private func beginFrame(_ apc: ArraySlice<UInt8>, _ command: KittyCommand) {
        var command = command
        guard command.imageID != nil || command.imageNumber != nil else {
            start([], KittyJob(command: command, landing: .discard))
            return
        }
        guard let target = animationTarget(command) else {
            missingImage(command)
            start([], KittyJob(command: command, landing: .discard))
            return
        }
        command.resolvedID = target.id
        let keys = Self.displayKeys.union(["I", "i"])
        let bytes = rewritten(apc, command, dropping: keys, setting: [("a", "T"), ("i", "\(Self.scratchImageID)"), ("C", "1")])
        start(bytes, KittyJob(command: command, landing: .frame))
    }

    func engineID(_ client: UInt32) -> UInt32 {
        if let existing = store.engineIDs[client] { return existing }
        let allocated = nextEngineID
        nextEngineID += 1
        store.engineIDs[client] = allocated
        return allocated
    }

    private func toEngine(_ bytes: [UInt8], _ job: inout KittyJob) -> [UInt8] {
        guard job.landing != .frame else { return bytes }
        resolveImage(&job.command)
        guard let id = job.command.imageID else { return bytes }
        return KittyGraphicsScanner.rewrite(bytes[...], dropping: ["I"], setting: [("i", "\(engineID(id))")])
    }

    private func execute(_ bytes: [UInt8], _ job: KittyJob) {
        var job = job
        resolveImage(&job.command)
        if job.command.transmits, let id = job.command.imageID {
            images.removeAll { $0.fromKitty && $0.kittyID == id }
            virtualPlacements.removeAll { $0.kittyID == id }
            sources[id] = nil
        }
        settled = nil
        activeJob = job
        run(bytes, filter: filter(for: job))
        activeJob = nil
        if job.command.transmits, let id = job.command.imageID {
            if sources[id] != nil {
                unloaded.remove(id)
                if let number = job.command.imageNumber {
                    imageNumbers[number] = id
                    nextImageID = id &+ 1
                }
                pin(id)
            } else {
                unloaded.insert(id)
            }
        }
        if let settled {
            let target = settled.row + settled.rows
            let current = cursorRow
            if current < target { terminal.feed(byteArray: Array(repeating: 0x0A, count: min(target - current, 10_000))) }
        }
        settled = nil
        finish(job)
        if job.command.transmits, let id = job.command.imageID, usedStorage > storageLimit { applyQuota(keeping: id) }
    }

    private func finish(_ job: KittyJob) {
        switch job.after {
        case .none:
            break
        case .virtual:
            registerVirtual(job.command)
        case .put:
            guard let id = job.command.imageID, sources[id] != nil else { return }
            let control = putControl(job.command, silent: job.silent)
            feedGraphics(Array("\u{1B}_G\(control)\u{1B}\\".utf8)[...], KittyGraphicsScanner.parse(Array(control.utf8)[...]))
        }
    }

    private func putControl(_ command: KittyCommand, silent: Bool) -> String {
        var keys = ["a=p"]
        if let number = command.imageNumber {
            keys.append("I=\(number)")
        } else if let id = command.imageID {
            keys.append("i=\(id)")
        }
        let optional: [(String, Int?)] = [
            ("p", silent ? nil : command.placementID.map { Int($0) }), ("c", command.columns), ("r", command.rows),
            ("x", command.x), ("y", command.y), ("w", command.cropWidth == 0 ? nil : command.cropWidth),
            ("h", command.cropHeight == 0 ? nil : command.cropHeight), ("X", command.pixelX), ("Y", command.pixelY),
            ("z", command.zIndex), ("C", command.cursorPolicy), ("q", silent ? 2 : command.quiet),
            ("P", command.parentImage.map { Int($0) }), ("Q", command.parentPlacement.map { Int($0) }),
            ("H", command.parentColumns), ("V", command.parentRows),
        ]
        for (key, value) in optional {
            if let value { keys.append("\(key)=\(value)") }
        }
        return keys.joined(separator: ",")
    }

    private func resolveImage(_ command: inout KittyCommand) {
        if command.transmits {
            if command.imageID == nil, command.imageNumber != nil { command.imageID = nextImageID }
        } else if command.action == "p", command.imageID == nil, let number = command.imageNumber {
            command.imageID = imageNumbers[number]
        }
    }

    private func animationTarget(_ command: KittyCommand) -> (id: UInt32, animation: KittyAnimation)? {
        guard let id = command.imageID ?? command.imageNumber.flatMap({ imageNumbers[$0] }),
              let animation = sources[id]
        else { return nil }
        return (id, animation)
    }

    func landKitty(_ image: NSImage, pixels: CGSize) -> Bool {
        guard let job = activeJob else { return false }
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        switch job.landing {
        case .frame:
            composeFrame(cgImage, job.command)
        case .harvest:
            store(cgImage, job.command)
        case .place:
            if job.command.transmits { store(cgImage, job.command) }
            recordKitty(image, pixels: pixels, command: job.command)
        case .discard:
            break
        }
        return true
    }

    private func store(_ image: CGImage?, _ command: KittyCommand) {
        guard let id = command.imageID, let image else { return }
        accessClock += 1
        sources[id] = KittyAnimation(
            root: image, opaque: KittyLoadCheck.format(command) == 24, transient: command.hints & 1 != 0, touched: accessClock
        )
    }

    private func recordKitty(_ image: NSImage, pixels: CGSize, command: KittyCommand) {
        let cell = cellPixels
        let columns = max(command.columns ?? 0, 0)
        let rows = max(command.rows ?? 0, 0)
        let offset = KittyGeometry.clampedOffset(command.pixelX, command.pixelY, cell: cell)
        let grid = KittyGeometry.grid(pixels: pixels, columns: columns, rows: rows, cell: cell, offset: offset)
        let row = cursorRow
        var placement = InlineImage(
            image: image,
            width: columns > 0 ? .cells(columns) : .auto,
            height: rows > 0 ? .cells(rows) : .auto,
            anchor: row, kittyID: command.imageID, fromKitty: true
        )
        placement.placementID = command.imageID == nil ? nil : command.placementID
        placement.zIndex = command.zIndex
        placement.column = min(terminal.buffer.x, max(terminal.cols - 1, 0))
        placement.rowSpan = grid.rows
        placement.columnSpan = grid.columns
        placement.pixelOffset = offset
        placement.pixelSize = pixels
        placement.scale = Self.backingScale
        if let id = command.imageID, let animation = sources[id] {
            placement.animation = animation
            if command.isCropped {
                let size = animation.size
                let left = max(command.x ?? 0, 0)
                let top = max(command.y ?? 0, 0)
                let width = command.cropWidth > 0 ? min(command.cropWidth, size.width - left) : size.width - left
                let height = command.cropHeight > 0 ? min(command.cropHeight, size.height - top) : size.height - top
                placement.crop = CGRect(x: left, y: top, width: width, height: height)
            }
        }
        if command.isRelative, let parent = command.parentImage {
            placement.parent = KittyParent(
                imageID: parent, placementID: command.parentPlacement ?? 0,
                columns: command.parentColumns, rows: command.parentRows
            )
        }
        if let id = command.imageID, let placementID = command.placementID {
            images.removeAll { $0.fromKitty && $0.kittyID == id && $0.placementID == placementID }
        }
        images.append(placement)
        if command.cursorPolicy != 1, !command.isRelative { settled = (row, grid.rows) }
    }

    private func composeFrame(_ data: CGImage?, _ command: KittyCommand) {
        guard let id = command.resolvedID, let animation = sources[id] else { return }
        guard let data else {
            fail(("EINVAL", "frame data could not be decoded"), command)
            return
        }
        let size = animation.size
        let count = animation.frames.count
        let requested = command.rows ?? 0
        let isNew = requested == 0 || requested > count
        let number = isNew ? count + 1 : requested
        if data.width > size.width {
            fail(("EINVAL", "Frame width \(data.width) larger than image width: \(size.width)"), command, frame: number)
            return
        }
        if data.height > size.height {
            fail(("EINVAL", "Frame height \(data.height) larger than image height: \(size.height)"), command, frame: number)
            return
        }
        let baseNumber = isNew ? (command.columns ?? 0) : requested
        guard baseNumber >= 0, baseNumber <= count else {
            fail(("EINVAL", "No frame with number: \(baseNumber) found"), command, frame: number)
            return
        }
        let base = baseNumber > 0 ? animation.frames[baseNumber - 1].image : nil
        guard let image = KittyCompositor.compose(
            base: base, width: size.width, height: size.height, background: UInt32(truncatingIfNeeded: command.pixelY),
            source: data, at: (command.x ?? 0, command.y ?? 0), replace: command.pixelX == 1
        ) else {
            fail(("EINVAL", "frame could not be composed"), command, frame: number)
            return
        }
        let gap = command.zIndex
        if isNew {
            let opaque = KittyLoadCheck.format(command) == 24
            let need = data.width * data.height * (opaque ? 3 : 4)
            if cacheSize + need > storageLimit * 5 {
                let placed = placedIDs()
                for candidate in Array(sources.keys) where candidate != id && !placed.contains(candidate) { evict(candidate) }
                if cacheSize + need > storageLimit * 5 {
                    fail(("ENOSPC", "Cache size exceeded cannot add new frames"), command, frame: number)
                    return
                }
            }
            animation.append(image, gap: gap > 0 ? gap : (gap < 0 ? 0 : KittyAnimation.defaultGap), bytes: need, opaque: opaque)
        } else {
            animation.replace(number - 1, with: image, gap: gap == 0 ? nil : max(gap, 0))
            if number == 1 { prime(id) }
        }
        emit(identity(command, frame: number), "OK", quiet: command.quiet)
    }

    private func controlAnimation(_ command: KittyCommand) {
        guard command.imageID != nil || command.imageNumber != nil else { return }
        guard let target = animationTarget(command) else {
            missingImage(command)
            return
        }
        let animation = target.animation
        if let frame = command.rows, frame > 0, frame <= animation.frames.count, command.zIndex != 0 {
            animation.setGap(command.zIndex, of: frame - 1)
        }
        if let frame = command.columns, frame > 0, frame <= animation.frames.count,
           frame - 1 != animation.frameIndex(at: Date()) {
            animation.show(frame - 1)
        }
        if let state = command.stateValue, (1...3).contains(state) { animation.setState(state) }
        if let loops = command.loopValue { animation.setLoops(loops) }
    }

    private func composeFrames(_ command: KittyCommand) {
        guard command.imageID != nil || command.imageNumber != nil else { return }
        guard let target = animationTarget(command) else {
            missingImage(command)
            return
        }
        let animation = target.animation
        let count = animation.frames.count
        let source = command.rows ?? 0
        let destination = command.columns ?? 0
        guard (1...count).contains(source) else {
            fail(("ENOENT", "No source frame number \(source) exists in image id: \(target.id)\n"), command)
            return
        }
        guard (1...count).contains(destination) else {
            fail(("ENOENT", "No destination frame number \(destination) exists in image id: \(target.id)\n"), command)
            return
        }
        let size = animation.size
        let width = command.cropWidth > 0 ? command.cropWidth : size.width
        let height = command.cropHeight > 0 ? command.cropHeight : size.height
        let from = CGRect(x: command.pixelX, y: command.pixelY, width: width, height: height)
        let to = CGRect(x: command.x ?? 0, y: command.y ?? 0, width: width, height: height)
        guard KittyCompositor.fits(to, width: size.width, height: size.height) else {
            fail(("EINVAL", "The destination rectangle is out of bounds"), command)
            return
        }
        guard KittyCompositor.fits(from, width: size.width, height: size.height) else {
            fail(("EINVAL", "The source rectangle is out of bounds"), command)
            return
        }
        guard source != destination || !from.intersects(to) else {
            fail(("EINVAL", "The source and destination rectangles overlap and the src and destination frames are the same"), command)
            return
        }
        guard let piece = animation.frames[source - 1].image.cropping(to: from),
              let image = KittyCompositor.compose(
                  base: animation.frames[destination - 1].image, width: size.width, height: size.height,
                  background: 0, source: piece, at: (Int(to.minX), Int(to.minY)), replace: command.cursorPolicy == 1
              )
        else {
            fail(("EINVAL", "Failed to get data for src frame: \(source - 1)"), command)
            return
        }
        animation.replace(destination - 1, with: image, gap: nil)
        if destination == 1 { prime(target.id) }
        emit(identity(command), "OK", quiet: command.quiet)
    }

    private func placeVirtual(_ command: KittyCommand) {
        var command = command
        resolveImage(&command)
        guard let id = command.imageID, sources[id] != nil else { return }
        registerVirtual(command)
        emit(identity(command), "OK", quiet: command.quiet)
    }

    private func registerVirtual(_ command: KittyCommand) {
        guard let id = command.imageID, let animation = sources[id] else { return }
        let root = animation.frames[0].image
        let pixels = CGSize(width: root.width, height: root.height)
        let columns = max(command.columns ?? 0, 0)
        let rows = max(command.rows ?? 0, 0)
        let grid = KittyGeometry.grid(pixels: pixels, columns: columns, rows: rows, cell: cellPixels, offset: .zero)
        var placement = InlineImage(
            image: NSImage(cgImage: root, size: NSSize(width: pixels.width, height: pixels.height)),
            width: columns > 0 ? .cells(columns) : .auto,
            height: rows > 0 ? .cells(rows) : .auto,
            anchor: 0, kittyID: id, fromKitty: true
        )
        placement.placementID = command.placementID
        placement.zIndex = command.zIndex
        placement.rowSpan = grid.rows
        placement.columnSpan = grid.columns
        placement.pixelSize = pixels
        placement.scale = Self.backingScale
        placement.animation = animation
        virtualPlacements.removeAll { $0.kittyID == id && $0.placementID == command.placementID }
        virtualPlacements.append(placement)
    }

    private func parentFailure(_ command: KittyCommand) -> (code: String, message: String)? {
        guard let parent = command.parentImage else { return ("ENOPARENT", "parent placement not found") }
        let parentKey = KittyKey(imageID: parent, placementID: command.parentPlacement ?? 0)
        guard images.hasPlacement(parent, parentKey.placementID) || virtualKeys.contains(parentKey) else {
            return ("ENOPARENT", "parent placement not found")
        }
        let key = (command.imageID ?? imageNumbers[command.imageNumber ?? 0], command.placementID ?? 0)
        guard let depth = images.chainDepth(from: parent, parentKey.placementID, replacing: key) else {
            return ("ECYCLE", "relative placement would form a cycle")
        }
        if depth > KittyGeometry.maxChainDepth { return ("ETOODEEP", "relative placement chain is too deep") }
        return nil
    }

    private func placedIDs() -> Set<UInt32> {
        Set(images.compactMap { $0.fromKitty ? $0.kittyID : nil }).union(virtualPlacements.compactMap(\.kittyID))
    }

    private func deleteImages(_ apc: ArraySlice<UInt8>, _ command: KittyCommand) {
        chunked = nil
        let mode = String(command.deleteTarget ?? "a").lowercased()
        if mode == "f" {
            deleteFrame(command)
            return
        }
        let before = placedIDs()
        if ["i", "n", "r"].contains(mode) {
            virtualPlacements.applyKittyDelete(command, context: deleteContext())
        }
        images.applyKittyDelete(command, context: deleteContext())
        guard let target = command.deleteTarget, target.isUppercase else { return }
        var candidates = before.subtracting(placedIDs())
        switch mode {
        case "i": if let id = command.imageID { candidates.insert(id) }
        case "n": if let number = command.imageNumber, let id = imageNumbers[number] { candidates.insert(id) }
        case "r": candidates.formUnion(sources.keys.filter { Int($0) >= (command.x ?? 0) && Int($0) <= (command.y ?? 0) })
        default: break
        }
        let placed = placedIDs()
        for id in candidates where !placed.contains(id) && sources[id] != nil { evict(id) }
    }

    private func deleteContext() -> KittyDeleteContext {
        let buffer = terminal.buffer
        return KittyDeleteContext(
            cursorRow: cursorRow,
            cursorColumn: buffer.x,
            screenTop: buffer.yDisp + buffer.totalLinesTrimmed,
            screenRows: terminal.rows,
            numbers: imageNumbers,
            virtualKeys: virtualKeys
        )
    }

    private func deleteFrame(_ command: KittyCommand) {
        guard let target = animationTarget(command) else { return }
        if target.animation.frames.count == 1 {
            if command.deleteTarget == "F" { evict(target.id) }
            return
        }
        target.animation.removeFrame(command.rows ?? 0)
    }

    static let pinPlacementID: UInt32 = 4_294_967_291
    static let probePlacementID: UInt32 = 4_294_967_292

    var usedStorage: Int {
        sources.values.reduce(0) { $0 + $1.rootBytes }
    }

    var cacheSize: Int {
        sources.values.reduce(0) { $0 + $1.totalBytes }
    }

    func evict(_ id: UInt32) {
        images.removeAll { $0.fromKitty && $0.kittyID == id }
        virtualPlacements.removeAll { $0.kittyID == id }
        images.removeOrphans(keeping: virtualKeys)
        sources[id] = nil
        unloaded.remove(id)
        imageNumbers = imageNumbers.filter { $0.value != id }
        let engine = engineID(id)
        store.engineIDs[id] = nil
        terminal.feed(byteArray: Array("\u{1B}_Ga=d,d=I,i=\(engine),p=\(Self.pinPlacementID),q=2\u{1B}\\".utf8))
    }

    private func pin(_ id: UInt32) {
        terminal.feed(byteArray: Array("\u{1B}_Ga=p,U=1,i=\(engineID(id)),p=\(Self.pinPlacementID),c=1,r=1,q=2\u{1B}\\".utf8))
    }

    func engineHasImage(_ id: UInt32) -> Bool {
        guard let engine = store.engineIDs[id] else { return false }
        var found = false
        let saved = onResponse
        onResponse = { data in
            if KittyReply.parse(data)?.ok == true { found = true }
        }
        terminal.feed(byteArray: Array("\u{1B}_Ga=p,U=1,i=\(engine),p=\(Self.probePlacementID),c=1,r=1\u{1B}\\".utf8))
        onResponse = saved
        if found {
            terminal.feed(byteArray: Array("\u{1B}_Ga=d,d=i,i=\(engine),p=\(Self.probePlacementID),q=2\u{1B}\\".utf8))
        }
        return found
    }

    func applyQuota(keeping id: UInt32?) {
        let placed = placedIDs()
        for candidate in Array(sources.keys) where candidate != id && !placed.contains(candidate) { evict(candidate) }
        guard usedStorage >= storageLimit else { return }
        let order = sources.sorted { first, second in
            first.value.transient != second.value.transient ? first.value.transient : first.value.touched < second.value.touched
        }
        for entry in order {
            guard usedStorage > storageLimit else { break }
            evict(entry.key)
        }
    }

    func withStore(_ target: KittyStore, _ body: () -> Void) {
        let saved = storeOverride
        storeOverride = target
        body()
        storeOverride = saved
    }

    func clearGraphics(all: Bool) {
        if all {
            images.removeAll { $0.fromKitty }
        } else {
            let top = terminal.buffer.yDisp + terminal.buffer.totalLinesTrimmed
            let snapshot = images
            let virtual = placeholderLayout().origins
            images.removeAll { image in
                guard image.fromKitty, let origin = snapshot.origin(of: image, virtual: virtual) else { return false }
                return origin.row + max(image.rowSpan, 1) > top
            }
        }
        images.removeOrphans(keeping: virtualKeys)
        let placed = placedIDs()
        for id in Array(sources.keys) where !placed.contains(id) { evict(id) }
    }

    func clearPlacements(_ scope: KittyGraphicsScanner.ClearScope) {
        switch scope {
        case .visible:
            clearGraphics(all: false)
        case .everything:
            clearGraphics(all: true)
        case .scrollback:
            pushScreenIntoScrollback()
            terminal.feed(byteArray: Array("\u{1B}[2J".utf8))
            clearGraphics(all: false)
        case .reset:
            withStore(normalStore) { clearGraphics(all: false) }
            withStore(altStore) { clearGraphics(all: true) }
        }
        primeRemaining()
    }

    private func pushScreenIntoScrollback() {
        guard !terminal.isCurrentBufferAlternate else { return }
        func blank(_ row: Int) -> Bool {
            guard let line = terminal.getLine(row: row) else { return true }
            for column in 0..<line.count {
                let character = terminal.getCharacter(for: line[column])
                if character != " " && character != "\u{0}" { return false }
            }
            return true
        }
        var count = terminal.rows
        while count > 0, blank(count - 1) { count -= 1 }
        guard count > 0 else { return }
        let sequence = "\u{1B}7\u{1B}[\(terminal.rows);1H" + String(repeating: "\n", count: count) + "\u{1B}8"
        terminal.feed(byteArray: Array(sequence.utf8))
    }

    func settleBufferSwitch() {
        guard pendingBufferSwitch else { return }
        pendingBufferSwitch = false
        withStore(altStore) { clearGraphics(all: true) }
        primeRemaining()
    }

    private func primeRemaining() {
        for target in [normalStore, altStore] {
            withStore(target) {
                for id in Array(sources.keys) where !engineHasImage(id) { prime(id) }
            }
        }
    }

    private func prime(_ id: UInt32) {
        guard let image = sources[id]?.frames[0].image, let pixels = Self.straightRGBA(image) else { return }
        let control = "a=t,f=32,s=\(image.width),v=\(image.height),i=\(engineID(id)),q=2"
        terminal.feed(byteArray: Array("\u{1B}_G\(control);\(Data(pixels).base64EncodedString())\u{1B}\\".utf8))
        pin(id)
    }

    private static func straightRGBA(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 { bytes[index + channel] = UInt8(min(255, Int(bytes[index + channel]) * 255 / alpha)) }
        }
        return bytes
    }

    func pruneScrolledOff() {
        let trimmed = terminal.buffer.totalLinesTrimmed
        guard trimmed > 0 else { return }
        images.removeAll { $0.fromKitty && $0.parent == nil && $0.anchor + max($0.rowSpan, 1) <= trimmed }
        images.removeOrphans(keeping: virtualKeys)
    }

    func placeholderLayout() -> (tiles: [InlineImage], origins: [KittyKey: (row: Int, column: Int)]) {
        guard !normalStore.virtualPlacements.isEmpty else { return ([], [:]) }
        let trimmed = terminal.buffer.totalLinesTrimmed
        let lineCount = terminal.buffer.yDisp + terminal.rows
        var cells: [KittyPlaceholderCell] = []
        for index in 0..<lineCount {
            guard let line = terminal.getScrollInvariantLine(row: index + trimmed) else { continue }
            var previous: (cell: KittyPlaceholderCell, attribute: Attribute)?
            for column in 0..<line.count {
                let data = line[column]
                if data.width == 0 { continue }
                let character = terminal.getCharacter(for: data)
                guard let cell = KittyPlaceholders.decode(
                    character, attribute: data.attribute, row: index + trimmed, column: column, previous: previous
                ) else { continue }
                cells.append(cell)
                previous = (cell, data.attribute)
            }
        }
        return KittyPlaceholders.tiles(of: cells, placements: normalStore.virtualPlacements)
    }
}
