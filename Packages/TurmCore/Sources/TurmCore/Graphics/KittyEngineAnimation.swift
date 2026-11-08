import CoreGraphics
import Foundation

extension KittyEngine {
    func composeFrame(_ data: CGImage, _ command: KittyCommand) {
        let store = activeStore
        guard let id = command.resolvedID, let animation = store.sources[id] else { return }
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
            let opaque = KittyDecoder.opaque(command: command)
            let need = data.width * data.height * (opaque ? 3 : 4)
            guard store.makeRoom(forFrameBytes: need, keeping: id).fits else {
                fail(("ENOSPC", "Cache size exceeded cannot add new frames"), command, frame: number)
                return
            }
            animation.append(image, gap: gap > 0 ? gap : (gap < 0 ? 0 : KittyAnimation.defaultGap), bytes: need, opaque: opaque)
        } else {
            animation.replace(number - 1, with: image, gap: gap == 0 ? nil : max(gap, 0))
        }
        emit(identity(command, frame: number), "OK", quiet: command.quiet)
    }

    func controlAnimation(_ command: KittyCommand) {
        guard command.imageID != nil || command.imageNumber != nil else { return }
        guard let target = animationTarget(command) else {
            missingImage(command)
            return
        }
        let animation = target.animation
        let date = now()
        if let frame = command.rows, frame > 0, frame <= animation.frames.count, command.zIndex != 0 {
            animation.setGap(command.zIndex, of: frame - 1)
        }
        if let frame = command.columns, frame > 0, frame <= animation.frames.count,
           frame - 1 != animation.frameIndex(at: date) {
            animation.show(frame - 1, now: date)
        }
        if let state = command.stateValue, (1...3).contains(state) { animation.setState(state, now: date) }
        if let loops = command.loopValue { animation.setLoops(loops) }
    }

    func composeFrames(_ command: KittyCommand) {
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
        emit(identity(command), "OK", quiet: command.quiet)
    }

    func deleteFrame(_ command: KittyCommand) {
        guard let target = animationTarget(command) else { return }
        if target.animation.frames.count == 1 {
            if command.deleteTarget == "F" { activeStore.evict(target.id) }
            return
        }
        target.animation.removeFrame(command.rows ?? 0, now: now())
    }
}
