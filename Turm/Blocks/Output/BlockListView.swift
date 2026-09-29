import AppKit
import CoreGraphics
import SwiftUI

struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var viewport: CGFloat = 0
    var content: CGFloat = 0
}

final class SelectionDriver {
    var metrics = ScrollMetrics()
    var active = false
    var moved = false
    var clicks = 1
    var pointerX: CGFloat = 0
    var viewportY: CGFloat = 0
    var task: Task<Void, Never>?
}

struct BlockListView: View {
    let session: TerminalSession
    @State private var position = ScrollPosition()
    @State private var driver = SelectionDriver()
    @State private var hoveredLink: URL?

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(session.blocks) { block in
                        BlockView(block: block, session: session)
                            .id(block.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .coordinateSpace(name: BlockSelection.space)
                .onContinuousHover(coordinateSpace: .named(BlockSelection.space)) { phase in
                    var link: URL?
                    if case .active(let point) = phase { link = session.selection.link(at: point) }
                    if link != hoveredLink { hoveredLink = link }
                }
            }
            .contentShape(Rectangle())
            .gesture(selectionGesture)
            .pointerStyle(hoveredLink != nil ? PointerStyle.link : nil)
            .help(hoveredLink?.absoluteString ?? "")
            .background(SelectionResponder(selection: session.selection))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.selection.listFrame = $0 }
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(offset: geometry.contentOffset.y, viewport: geometry.containerSize.height, content: geometry.contentSize.height)
            } action: { _, metrics in
                driver.metrics = metrics
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: session.blocks.count) { scrollToBottom(reader) }
            .onChange(of: session.current?.output) { scrollToBottom(reader) }
            .onChange(of: session.current?.segments.count) { scrollToBottom(reader) }
            .onChange(of: session.search.scrollRequest) { _, request in
                guard let request else { return }
                reader.scrollTo(request.blockID, anchor: UnitPoint(x: 0, y: request.position))
            }
        }
        .overlay {
            if let failure = session.failure {
                Text(failure)
                    .foregroundStyle(Theme.failure.color)
                    .padding()
            }
        }
    }

    private static let bottom = "turm.bottom"

    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !driver.active {
                    guard !NSEvent.modifierFlags.contains(.control) else { return }
                    driver.active = true
                    driver.moved = false
                    driver.clicks = NSApp.currentEvent?.clickCount ?? 1
                    session.selection.press(
                        at: contentPoint(value.startLocation), clicks: driver.clicks,
                        extend: NSEvent.modifierFlags.contains(.shift)
                    )
                }
                guard driver.active else { return }
                driver.pointerX = value.location.x
                driver.viewportY = value.location.y
                if !driver.moved, hypot(value.translation.width, value.translation.height) > 3 { driver.moved = true }
                if driver.moved {
                    session.selection.drag(to: contentPoint(value.location))
                    startAutoscroll()
                }
            }
            .onEnded { value in
                driver.task?.cancel()
                driver.task = nil
                if driver.active, !driver.moved, driver.clicks == 1, let url = session.selection.link(at: contentPoint(value.location)) {
                    NSWorkspace.shared.open(url)
                }
                if driver.active { session.selection.hasSelection ? session.selection.claimFocus() : session.selection.releaseFocus() }
                driver.active = false
            }
    }

    private func contentPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y + driver.metrics.offset)
    }

    private func startAutoscroll() {
        guard driver.task == nil else { return }
        let driver = driver
        driver.task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                let metrics = driver.metrics
                let overshoot = driver.viewportY < 0 ? driver.viewportY : max(driver.viewportY - metrics.viewport, 0)
                guard overshoot != 0 else { continue }
                let step = min(max(overshoot * 0.4, -48), 48)
                let limit = max(metrics.content - metrics.viewport, 0)
                let target = min(max(metrics.offset + step, 0), limit)
                guard target != metrics.offset else { continue }
                position.scrollTo(y: target)
                driver.metrics.offset = target
                session.selection.drag(to: CGPoint(x: driver.pointerX, y: driver.viewportY + target))
            }
        }
    }

    private func scrollToBottom(_ reader: ScrollViewProxy) {
        guard !(session.search.isPresented && !session.search.query.isEmpty) else { return }
        reader.scrollTo(Self.bottom, anchor: .bottom)
    }
}

struct BlockView: View {
    let block: Block
    let session: TerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            PieceText(
                text: commandText,
                highlights: session.search.commandHighlights(for: block),
                piece: PieceRef(id: PieceID(blockID: block.id, target: .command), host: session.selection)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            if block.hasOutput {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(block.segments.enumerated()), id: \.offset) { index, segment in
                        switch segment {
                        case .text(let text):
                            PieceText(
                                text: text,
                                highlights: session.search.highlights(for: block, segment: index),
                                piece: pieceRef(index)
                            )
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .image(let image):
                            InlineImageView(image: image)
                        case .stack(let stack):
                            ImageStackView(stack: stack, highlights: session.search.highlights(for: block, segment: index), piece: pieceRef(index))
                        }
                    }
                }
                .padding(.top, 6)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TerminalSession.paneSpace)) } action: { frame in
                    session.setRunningOutputFrame(frame, for: block)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(block.failed ? Theme.failure.color.opacity(0.07) : Color.clear)
        .overlay(alignment: .leading) {
            if block.failed { Rectangle().fill(Theme.failure.color).frame(width: 2) }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.subtleDivider.color).frame(height: 1)
        }
        .contextMenu {
            Button("Copy Command") { copy(block.command) }
            Button("Copy Output") { copy(block.plainOutput) }
                .disabled(block.output.isEmpty)
            Button("Run Again") { session.submit(block.command) }
                .disabled(session.phase != .ready)
        }
    }

    private var commandText: AttributedString {
        var container = AttributeContainer()
        container.appKit.foregroundColor = TerminalPalette.textColor
        container[FontStyleKey.self] = 1
        return AttributedString(block.command, attributes: container)
    }

    private func pieceRef(_ index: Int) -> PieceRef {
        PieceRef(id: PieceID(blockID: block.id, target: .segment(index)), host: session.selection)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(Block.abbreviate(block.directory))
            if let git = block.git {
                Text("git:(\(git.branch))")
                Text("\(git.files) \u{2022} +\(git.added) -\(git.removed)")
            }
            if let code = block.exitCode, code != 0 {
                Text("exit \(code)").foregroundStyle(Theme.failure.color)
            }
            if let duration = block.duration {
                Text("(\(Block.formatDuration(duration)))")
            } else if block.isRunning {
                Text("running")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Theme.secondaryText.color)
        .lineLimit(1)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct InlineImageView: View {
    let image: InlineImage

    var body: some View {
        if image.rowSpan > 0 {
            KittyImageBand(rows: image.rowSpan, start: image.anchor, images: [image], behind: [], text: nil)
        } else {
            let size = image.requestedSize(cellWidth: TerminalMetrics.cellWidth, lineHeight: TerminalMetrics.lineHeight)
            Image(nsImage: image.image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: size.width, maxHeight: size.height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
    }
}

struct ImageStackView: View {
    let stack: ImageStack
    var highlights: SegmentHighlights = .none
    var piece: PieceRef?

    var body: some View {
        KittyImageBand(
            rows: stack.rows, start: stack.start,
            images: stack.images.filter { $0.zIndex >= 0 },
            behind: stack.images.filter { $0.zIndex < 0 },
            text: stack.lines.isEmpty ? nil : stack.text,
            highlights: highlights,
            piece: piece
        )
    }
}

struct KittyImageBand: View {
    let rows: Int
    let start: Int
    let images: [InlineImage]
    let behind: [InlineImage]
    let text: AttributedString?
    var highlights: SegmentHighlights = .none
    var piece: PieceRef?

    var body: some View {
        let lineHeight = TerminalMetrics.lineHeight
        ZStack(alignment: .topLeading) {
            ForEach(behind) { placed($0) }
            if let text {
                Group {
                    if let piece {
                        PieceText(text: text, highlights: highlights, piece: piece)
                    } else {
                        BlockTextView(text: text, highlights: highlights)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            ForEach(images) { placed($0) }
        }
        .frame(maxWidth: .infinity, minHeight: CGFloat(rows) * lineHeight, maxHeight: CGFloat(rows) * lineHeight, alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder
    private func placed(_ image: InlineImage) -> some View {
        let cellWidth = TerminalMetrics.cellWidth
        let lineHeight = TerminalMetrics.lineHeight
        let x = CGFloat(image.column) * cellWidth + image.pixelOffset.width / image.scale
        let y = CGFloat(image.anchor - start) * lineHeight + image.pixelOffset.height / image.scale
        if let tile = image.tile {
            KittyImageContent(image: image)
                .frame(width: CGFloat(tile.columns) * cellWidth, height: CGFloat(tile.rows) * lineHeight)
                .offset(x: -CGFloat(tile.partColumn) * cellWidth, y: -CGFloat(tile.partRow) * lineHeight)
                .frame(width: CGFloat(image.columnSpan) * cellWidth, height: lineHeight, alignment: .topLeading)
                .background { if let background = image.background { Color(nsColor: background) } }
                .clipped()
                .offset(x: x, y: y)
                .allowsHitTesting(false)
        } else {
            let size = image.requestedSize(cellWidth: cellWidth, lineHeight: lineHeight)
            KittyImageContent(image: image)
                .frame(width: size.width, height: size.height)
                .offset(x: x, y: y)
                .allowsHitTesting(false)
        }
    }
}

struct KittyImageContent: View {
    let image: InlineImage

    var body: some View {
        if let animation = image.animation, animation.frames.count > 1 {
            AnimatedKittyFrame(image: image, animation: animation)
        } else {
            Image(nsImage: image.image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
    }
}

struct AnimatedKittyFrame: View {
    let image: InlineImage
    let animation: KittyAnimation
    @Environment(\.controlActiveState) private var activeState
    @State private var visible = true

    var body: some View {
        let paused = !visible || activeState == .inactive || !animation.isRunning
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
            Image(decorative: animation.frame(at: context.date, cropping: image.crop), scale: image.scale)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
        .onScrollVisibilityChange { visible = $0 }
    }
}
