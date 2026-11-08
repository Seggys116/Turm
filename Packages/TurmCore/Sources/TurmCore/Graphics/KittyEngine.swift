import CoreGraphics
import Foundation

public final class KittyEngine {
    enum Landing {
        case place
        case harvest
        case frame
        case query
        case discard
    }

    enum After {
        case none
        case put
        case virtual
    }

    struct Job {
        var command: KittyCommand
        var landing: Landing
        var after = After.none
        var silent = false
        var load = KittyLoadState()
    }

    struct Settled {
        let row: Int
        let column: Int
        let rows: Int
        let columns: Int
    }

    static let lineFeedLimit = 10_000

    public let store: KittyImageStore
    public let alternateStore: KittyImageStore
    public private(set) var revision: UInt64 = 0
    public private(set) var isAlternate = false
    let now: () -> Date
    var host: (any GraphicsHost)?
    private var chunked: Job?

    public var activeStore: KittyImageStore {
        isAlternate ? alternateStore : store
    }

    public init(storageLimit: Int = 320 << 20, now: @escaping () -> Date = Date.init) {
        store = KittyImageStore()
        alternateStore = KittyImageStore()
        store.storageLimit = storageLimit
        alternateStore.storageLimit = storageLimit
        self.now = now
    }

    public func handle(_ apc: ArraySlice<UInt8>, host: any GraphicsHost) {
        let bytes = Array(apc)
        guard bytes.count >= 3, bytes[0] == 0x1B, bytes[1] == 0x5F, bytes[2] == 0x47 else { return }
        self.host = host
        defer { self.host = nil }
        sync(host)
        let terminated = bytes.count >= 5 && bytes[bytes.count - 2] == 0x1B && bytes[bytes.count - 1] == 0x5C
        let body = bytes[3..<(terminated ? bytes.count - 2 : bytes.count)]
        let separator = body.firstIndex(of: 0x3B)
        let command = KittyGraphicsScanner.parse(separator.map { body[..<$0] } ?? body)
        let payload = separator.map { body[($0 + 1)...] } ?? []
        dispatch(command, payload: payload)
        if command.action != "q", chunked == nil || chunked?.landing == .discard { changed() }
    }

    public func placements(visible rows: Range<Int>, host: any GraphicsHost) -> [GraphicsPlacement] {
        self.host = host
        defer { self.host = nil }
        sync(host)
        let store = activeStore
        let holders = layout(store, rows: rows)
        var result: [GraphicsPlacement] = []
        for image in store.images where image.rowSpan > 0 {
            guard let origin = store.images.origin(of: image, virtual: holders.origins),
                  origin.row < rows.upperBound, origin.row + image.rowSpan > rows.lowerBound
            else { continue }
            var placed = image
            placed.origin = origin
            result.append(placed)
        }
        result.append(contentsOf: holders.tiles)
        return result.enumerated()
            .sorted { ($0.element.zIndex, $0.offset) < ($1.element.zIndex, $1.offset) }
            .map(\.element)
    }

    public func clear(_ scope: KittyGraphicsScanner.ClearScope, host: any GraphicsHost) {
        self.host = host
        defer { self.host = nil }
        sync(host)
        switch scope {
        case .visible, .scrollback:
            clearGraphics(activeStore, all: false)
        case .everything:
            clearGraphics(activeStore, all: true)
        case .reset:
            clearGraphics(store, all: false)
            clearGraphics(alternateStore, all: true)
        }
        changed()
    }

    public func clearAll() {
        for target in [store, alternateStore] {
            target.images = []
            target.virtualPlacements = []
            target.sources = [:]
            target.imageNumbers = [:]
            target.nextImageID = 1
            target.nextInternalID = KittyImageStore().nextInternalID
            target.unloaded = []
            target.accessClock = 0
            target.engineIDs = [:]
        }
        chunked = nil
        isAlternate = false
        changed()
    }

    public func bufferSwitched(toAlternate: Bool) {
        guard toAlternate != isAlternate else { return }
        isAlternate = toAlternate
        // a program entering the alternate screen starts from an empty image table, as kitty does
        if toAlternate { clearGraphics(alternateStore, all: true) }
        changed()
    }

    public func pruneScrolledOff(trimmed: Int) {
        guard trimmed > 0 else { return }
        let store = activeStore
        let before = store.images.count
        store.images.removeAll { image in
            let end = image.origin.row + max(image.rowSpan, 1)
            if image.fromKitty { return image.parent == nil && end <= trimmed }
            return image.rowSpan > 0 && end <= trimmed
        }
        store.images.removeOrphans(keeping: store.virtualKeys)
        if store.images.count != before { changed() }
    }

    func changed() {
        revision &+= 1
    }

    private func sync(_ host: any GraphicsHost) {
        if host.screen.alternate != isAlternate { bufferSwitched(toAlternate: host.screen.alternate) }
    }

    var cell: (width: Int, height: Int) {
        guard let screen = host?.screen else { return (0, 0) }
        return (screen.cellWidth, screen.cellHeight)
    }

    func emit(_ control: String, _ message: String, quiet: Int) {
        guard quiet == 0 || (quiet == 1 && message != "OK") else { return }
        host?.reply(Array("\u{1B}_G\(control);\(message)\u{1B}\\".utf8))
    }

    func identity(_ command: KittyCommand, frame: Int? = nil) -> String {
        var parts: [String] = []
        if let id = command.imageID { parts.append("i=\(id)") }
        if let number = command.imageNumber { parts.append("I=\(number)") }
        if let placement = command.placementID { parts.append("p=\(placement)") }
        if let frame, frame > 0, command.action == "f" || command.action == "a" { parts.append("r=\(frame)") }
        return parts.joined(separator: ",")
    }

    // Errors raised while decoding or displaying name only the image, never the placement.
    private func imageControl(_ command: KittyCommand) -> String {
        guard let id = command.imageID else { return "" }
        return "i=\(id)" + (command.imageNumber.map { ",I=\($0)" } ?? "")
    }

    func fail(_ failure: (code: String, message: String), _ command: KittyCommand, frame: Int? = nil) {
        emit(identity(command, frame: frame ?? command.rows), "\(failure.code):\(failure.message)", quiet: command.quiet)
    }

    func missingImage(_ command: KittyCommand) {
        let message = "Animation command refers to non-existent image with id: \(command.imageID ?? 0) and number: \(command.imageNumber ?? 0)"
        fail(("ENOENT", message), command)
    }

    private func dispatch(_ command: KittyCommand, payload: ArraySlice<UInt8>) {
        if command.action == nil, chunked != nil {
            continueChunk(payload, command)
            return
        }
        var command = command
        let action = command.action ?? "t"
        command.action = action
        if command.imageID != nil, command.imageNumber != nil, "acdfpq".contains(action) {
            fail(("EINVAL", "Must not specify both image id and image number"), command)
            if action == "f", command.more { start(payload, Job(command: command, landing: .discard)) }
            return
        }
        switch action {
        case "d": deleteImages(command)
        case "a": controlAnimation(command)
        case "c": composeFrames(command)
        case "f": beginFrame(payload, command)
        case "t", "T": beginTransmit(payload, command)
        case "p": beginPut(command)
        case "q": start(payload, Job(command: command, landing: .query))
        case "D": break
        default:
            let control = command.imageID.map { "i=\($0)" } ?? command.imageNumber.map { "I=\($0)" } ?? ""
            emit(control, "EINVAL:unsupported action", quiet: command.quiet)
        }
    }

    private func accept(_ job: inout Job, _ payload: ArraySlice<UInt8>, more: Bool) -> KittyFailure? {
        KittyLoadCheck.accept(
            &job.load, chunk: payload, command: job.command, more: more, allowsLocalMedia: host?.allowsLocalMedia ?? false
        )
    }

    private func start(_ payload: ArraySlice<UInt8>, _ job: Job) {
        var job = job
        if job.landing == .discard {
            if job.command.more { chunked = job }
            return
        }
        if let failure = KittyLoadCheck.initialize(job.command) ?? accept(&job, payload, more: job.command.more) {
            reject(failure, job, more: job.command.more)
            return
        }
        if job.landing == .query {
            finishQuery(job, more: job.command.more)
            return
        }
        // compressed chunks were held back whole, so their image id was only resolved at the end
        if job.landing != .frame, !(job.command.compression == "z" && job.command.more) { resolveImage(&job.command) }
        if job.command.more {
            chunked = job
        } else {
            execute(job)
            KittyLoadCheck.discardTransient(job.load, job.command)
        }
    }

    private func continueChunk(_ payload: ArraySlice<UInt8>, _ command: KittyCommand) {
        guard var job = chunked else { return }
        if job.landing == .discard {
            if !command.more { chunked = nil }
            return
        }
        if let failure = accept(&job, payload, more: command.more) {
            reject(failure, job, more: command.more)
            return
        }
        if job.landing == .query {
            finishQuery(job, more: command.more)
            return
        }
        if command.more {
            chunked = job
        } else {
            chunked = nil
            execute(job)
            KittyLoadCheck.discardTransient(job.load, job.command)
        }
    }

    private func finishQuery(_ job: Job, more: Bool) {
        if more {
            chunked = job
            return
        }
        chunked = nil
        emit(identity(job.command), "OK", quiet: job.command.quiet)
        KittyLoadCheck.discardTransient(job.load, job.command)
    }

    private func reject(_ failure: KittyFailure, _ job: Job, more: Bool) {
        if !job.silent { fail((failure.code, failure.message), job.command) }
        KittyLoadCheck.discardTransient(job.load, job.command)
        if job.command.transmits, let id = job.command.imageID {
            activeStore.evict(id)
            activeStore.unloaded.insert(id)
        }
        chunked = more ? Job(command: job.command, landing: .discard) : nil
    }

    private func beginTransmit(_ payload: ArraySlice<UInt8>, _ source: KittyCommand) {
        var command = source
        var silent = false
        if command.action == "T", command.isCropped, !command.virtual, command.imageID == nil, command.imageNumber == nil {
            command.imageID = activeStore.allocateInternalID()
            silent = true
        }
        let addressable = command.imageID != nil || command.imageNumber != nil
        var job = Job(command: command, landing: .place, silent: silent)
        if command.action == "t" {
            job.landing = .harvest
        } else if command.virtual, addressable {
            job.landing = .harvest
            job.after = .virtual
        } else if command.isCropped, addressable {
            job.landing = .harvest
            job.after = .put
        } else if command.isRelative, let failure = parentFailure(command) {
            fail(failure, command)
            job.landing = .harvest
        }
        start(payload, job)
    }

    private func admitPut(_ command: KittyCommand) -> Bool {
        guard command.imageID != nil || command.imageNumber != nil else { return false }
        let store = activeStore
        let id = store.resolve(imageID: command.imageID, imageNumber: command.imageNumber)
        if let id, store.sources[id] != nil {
            store.touch(id)
            return true
        }
        if let id, store.unloaded.contains(id) {
            fail(("ENOENT", "Put command refers to image with id: \(id) that could not load its data"), command)
        } else {
            let message = "Put command refers to non-existent image with id: \(command.imageID ?? 0) and number: \(command.imageNumber ?? 0)"
            fail(("ENOENT", message), command)
        }
        return false
    }

    private func beginPut(_ command: KittyCommand) {
        guard admitPut(command) else { return }
        if command.virtual {
            placeVirtual(command)
            return
        }
        if command.isRelative, let failure = parentFailure(command) {
            fail(failure, command)
            return
        }
        var job = Job(command: command, landing: .place)
        resolveImage(&job.command)
        execute(job)
    }

    private func beginFrame(_ payload: ArraySlice<UInt8>, _ command: KittyCommand) {
        var command = command
        guard command.imageID != nil || command.imageNumber != nil else {
            start(payload, Job(command: command, landing: .discard))
            return
        }
        guard let target = animationTarget(command) else {
            missingImage(command)
            start(payload, Job(command: command, landing: .discard))
            return
        }
        command.resolvedID = target.id
        start(payload, Job(command: command, landing: .frame))
    }

    func resolveImage(_ command: inout KittyCommand) {
        if command.transmits {
            if command.imageID == nil, command.imageNumber != nil { command.imageID = activeStore.nextImageID }
        } else if command.action == "p", command.imageID == nil, let number = command.imageNumber {
            command.imageID = activeStore.imageNumbers[number]
        }
    }

    func animationTarget(_ command: KittyCommand) -> (id: UInt32, animation: KittyAnimation)? {
        guard let id = activeStore.resolve(imageID: command.imageID, imageNumber: command.imageNumber),
              let animation = activeStore.sources[id]
        else { return nil }
        return (id, animation)
    }

    private func execute(_ job: Job) {
        var job = job
        resolveImage(&job.command)
        let command = job.command
        let store = activeStore
        if command.transmits, let id = command.imageID {
            store.images.removeAll { $0.fromKitty && $0.kittyID == id }
            store.virtualPlacements.removeAll { $0.kittyID == id }
            store.sources[id] = nil
        }
        let settled = land(job)
        if command.transmits, let id = command.imageID {
            if store.sources[id] != nil {
                store.unloaded.remove(id)
                if let number = command.imageNumber {
                    store.imageNumbers[number] = id
                    store.nextImageID = id &+ 1
                }
            } else {
                store.unloaded.insert(id)
            }
        }
        if let settled { moveCursor(past: settled) }
        finish(job)
        if command.transmits, let id = command.imageID, store.usedStorage > store.storageLimit {
            _ = store.applyQuota(keeping: id)
        }
    }

    private func land(_ job: Job) -> Settled? {
        let command = job.command
        let quiet = job.silent ? 2 : command.quiet
        switch job.landing {
        case .frame:
            let control = command.imageID.map { "i=\($0)" } ?? command.imageNumber.map { "I=\($0)" } ?? ""
            guard let image = decode(job, control: control, quiet: quiet) else { return nil }
            composeFrame(image, command)
        case .harvest:
            guard let image = decode(job, control: imageControl(command), quiet: quiet) else { return nil }
            keep(image, command)
            if command.imageID != nil, job.after != .put { emit(imageControl(command), "OK", quiet: quiet) }
        case .place:
            let image: CGImage
            if command.transmits {
                guard let decoded = decode(job, control: imageControl(command), quiet: quiet) else { return nil }
                keep(decoded, command)
                image = decoded
            } else {
                guard let id = command.imageID, let root = activeStore.sources[id]?.frames[0].image else { return nil }
                image = root
            }
            let shown = display(image, command, quiet: quiet)
            guard shown.placed else { return nil }
            if command.imageID != nil { emit(identity(command), "OK", quiet: quiet) }
            return shown.cursor
        case .query, .discard:
            break
        }
        return nil
    }

    private func decode(_ job: Job, control: String, quiet: Int) -> CGImage? {
        guard let data = KittyLoadCheck.bytes(job.load, command: job.command) else {
            let message: String
            if KittyLoadCheck.isFile(job.command) {
                message = "EBADF:Failed to read image file"
            } else if KittyLoadCheck.format(job.command) == 100 {
                message = "EBADPNG:Failed to decode PNG data"
            } else {
                message = "EINVAL:bad payload"
            }
            emit(control, message, quiet: quiet)
            return nil
        }
        switch KittyDecoder.decode(command: job.command, bytes: data) {
        case .success(let image):
            return image
        case .failure(let failure):
            emit(control, "\(failure.code):\(failure.message)", quiet: quiet)
            return nil
        }
    }

    private func keep(_ image: CGImage, _ command: KittyCommand) {
        guard let id = command.imageID else { return }
        let store = activeStore
        store.accessClock += 1
        store.sources[id] = KittyAnimation(
            root: image, opaque: KittyDecoder.opaque(command: command), transient: command.hints & 1 != 0,
            touched: store.accessClock
        )
    }

    private func display(_ image: CGImage, _ command: KittyCommand, quiet: Int) -> (placed: Bool, cursor: Settled?) {
        if command.virtual { return (true, nil) }
        var pixels = CGSize(width: image.width, height: image.height)
        var crop: CGRect?
        if command.isCropped {
            let left = max(0, min(command.x ?? 0, image.width))
            let top = max(0, min(command.y ?? 0, image.height))
            let width = max(0, min(command.cropWidth > 0 ? command.cropWidth : image.width - left, image.width - left))
            let height = max(0, min(command.cropHeight > 0 ? command.cropHeight : image.height - top, image.height - top))
            guard width > 0, height > 0 else {
                emit(imageControl(command), "EINVAL:bad crop", quiet: quiet)
                return (false, nil)
            }
            crop = CGRect(x: left, y: top, width: width, height: height)
            pixels = CGSize(width: width, height: height)
        }
        guard let host else { return (false, nil) }
        let screen = host.screen
        let columns = max(command.columns ?? 0, 0)
        let rows = max(command.rows ?? 0, 0)
        let offset = KittyGeometry.clampedOffset(command.pixelX, command.pixelY, cell: cell)
        let grid = KittyGeometry.grid(pixels: pixels, columns: columns, rows: rows, cell: cell, offset: offset)
        let cursor = host.cursor
        let store = activeStore
        var source = GraphicsSource.still(image)
        if let id = command.imageID, let animation = store.sources[id] {
            source = .animated(animation)
        } else {
            crop = nil
        }
        var placement = GraphicsPlacement(
            source: source, origin: GridPoint(row: cursor.row, column: min(cursor.column, max(screen.columns - 1, 0)))
        )
        placement.kittyID = command.imageID
        placement.fromKitty = true
        placement.placementID = command.imageID == nil ? nil : command.placementID
        placement.zIndex = command.zIndex
        placement.rowSpan = grid.rows
        placement.columnSpan = grid.columns
        placement.pixelOffset = offset
        placement.pixelSize = pixels
        placement.scale = CGFloat(screen.scale)
        placement.crop = crop
        if command.isRelative, let parent = command.parentImage {
            placement.parent = KittyParent(
                imageID: parent, placementID: command.parentPlacement ?? 0,
                columns: command.parentColumns, rows: command.parentRows
            )
        }
        if let id = command.imageID, let placementID = command.placementID {
            store.images.removeAll { $0.fromKitty && $0.kittyID == id && $0.placementID == placementID }
        }
        store.images.append(placement)
        guard command.cursorPolicy != 1, !command.isRelative else { return (true, nil) }
        return (true, Settled(row: cursor.row, column: cursor.column, rows: grid.rows, columns: grid.columns))
    }

    // "\n" per image row (scrolls at the bottom like output), then ESC [ n G to the column after it, clamped
    private func moveCursor(past settled: Settled) {
        guard let host else { return }
        let screen = host.screen
        var bytes: [UInt8] = []
        let current = host.cursor.row
        let target = settled.row + settled.rows
        if current < target {
            let bottom = screen.top + screen.rows - 1
            let count = min(target - current, max(bottom - current, 0) + Self.lineFeedLimit)
            bytes.append(contentsOf: repeatElement(0x0A, count: count))
        }
        let column = max(0, min(settled.column + settled.columns, screen.columns - 1))
        bytes.append(contentsOf: Array("\u{1B}[\(column + 1)G".utf8))
        host.feedTerminal(bytes[...])
    }

    private func finish(_ job: Job) {
        switch job.after {
        case .none:
            break
        case .virtual:
            registerVirtual(job.command)
        case .put:
            guard let id = job.command.imageID, activeStore.sources[id] != nil else { return }
            let control = putControl(job.command, silent: job.silent)
            dispatch(KittyGraphicsScanner.parse(Array(control.utf8)[...]), payload: [])
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

    private func placeVirtual(_ command: KittyCommand) {
        var command = command
        resolveImage(&command)
        guard let id = command.imageID, activeStore.sources[id] != nil else { return }
        registerVirtual(command)
        emit(identity(command), "OK", quiet: command.quiet)
    }

    private func registerVirtual(_ command: KittyCommand) {
        let store = activeStore
        guard let id = command.imageID, let animation = store.sources[id] else { return }
        var root = animation.frames[0].image
        var crop: CGRect?
        if command.isCropped {
            let left = max(command.x ?? 0, 0)
            let top = max(command.y ?? 0, 0)
            let width = command.cropWidth > 0 ? min(command.cropWidth, root.width - left) : root.width - left
            let height = command.cropHeight > 0 ? min(command.cropHeight, root.height - top) : root.height - top
            let rect = CGRect(x: left, y: top, width: width, height: height)
            if width > 0, height > 0, let cropped = root.cropping(to: rect) {
                root = cropped
                crop = rect
            }
        }
        let pixels = CGSize(width: root.width, height: root.height)
        let columns = max(command.columns ?? 0, 0)
        let rows = max(command.rows ?? 0, 0)
        let grid = KittyGeometry.grid(pixels: pixels, columns: columns, rows: rows, cell: cell, offset: .zero)
        var placement = GraphicsPlacement(source: .animated(animation), origin: GridPoint(row: 0, column: 0))
        placement.kittyID = id
        placement.fromKitty = true
        placement.placementID = command.placementID
        placement.zIndex = command.zIndex
        placement.rowSpan = grid.rows
        placement.columnSpan = grid.columns
        placement.pixelSize = pixels
        placement.scale = CGFloat(host?.screen.scale ?? 1)
        placement.crop = crop
        store.virtualPlacements.removeAll { $0.kittyID == id && $0.placementID == command.placementID }
        store.virtualPlacements.append(placement)
    }

    private func parentFailure(_ command: KittyCommand) -> (code: String, message: String)? {
        let store = activeStore
        guard let parent = command.parentImage else { return ("ENOPARENT", "parent placement not found") }
        let parentKey = KittyKey(imageID: parent, placementID: command.parentPlacement ?? 0)
        guard store.images.hasPlacement(parent, parentKey.placementID) || store.virtualKeys.contains(parentKey) else {
            return ("ENOPARENT", "parent placement not found")
        }
        let key = (command.imageID ?? store.imageNumbers[command.imageNumber ?? 0], command.placementID ?? 0)
        guard let depth = store.images.chainDepth(from: parent, parentKey.placementID, replacing: key) else {
            return ("ECYCLE", "relative placement would form a cycle")
        }
        if depth > KittyGeometry.maxChainDepth { return ("ETOODEEP", "relative placement chain is too deep") }
        return nil
    }

    private func deleteImages(_ command: KittyCommand) {
        chunked = nil
        if String(command.deleteTarget ?? "a").lowercased() == "f" {
            deleteFrame(command)
            return
        }
        guard let host else { return }
        _ = activeStore.deletePlacements(command, cursor: host.cursor, screen: host.screen)
    }

    private func clearGraphics(_ store: KittyImageStore, all: Bool) {
        if all {
            store.images.removeAll()
        } else if let screen = host?.screen {
            let top = screen.top
            let snapshot = store.images
            let virtual = layout(store, rows: 0..<max(top + screen.rows, 0)).origins
            store.images.removeAll { image in
                let origin = snapshot.origin(of: image, virtual: virtual)?.row ?? image.origin.row
                return origin + max(image.rowSpan, 1) > top
            }
        }
        store.images.removeOrphans(keeping: store.virtualKeys)
        let placed = store.placedIDs()
        for id in Array(store.sources.keys) where !placed.contains(id) { store.evict(id) }
    }

    private func layout(_ store: KittyImageStore, rows: Range<Int>) -> (tiles: [GraphicsPlacement], origins: [KittyKey: GridPoint]) {
        guard !store.virtualPlacements.isEmpty, let host else { return ([], [:]) }
        let cells = KittyPlaceholders.decode(host.placeholderCells(rows: rows))
        var backgrounds: [GridPoint: GraphicsColor] = [:]
        for cell in cells { backgrounds[GridPoint(row: cell.row, column: cell.column)] = cell.background }
        let result = KittyPlaceholders.tiles(of: cells, placements: store.virtualPlacements)
        let tiles = result.tiles.map { tile -> GraphicsPlacement in
            var tile = tile
            tile.background = backgrounds[tile.origin] ?? .none
            return tile
        }
        return (tiles, result.origins)
    }
}
