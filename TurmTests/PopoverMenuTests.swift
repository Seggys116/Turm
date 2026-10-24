import AppKit
import SwiftUI
import Testing
@testable import Turm

@MainActor
@Suite(.serialized)
struct PopoverMenuTests {
    @Test func rightClickMenuStaysArmedAfterItOpensAndCloses() {
        let controller = MenuController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 8, y: 8, width: 120, height: 24))
        window.contentView?.addSubview(view)
        defer {
            controller.teardown()
            window.close()
        }

        controller.attachChip(to: view)
        controller.installTrigger {}
        #expect(view.window === window)

        let menu = AnyView(Color.clear.frame(width: 80, height: 40))
        controller.present(menu, placement: .pointer(.zero))
        #expect(controller.isShowingMenu)
        #expect(controller.rightClickInstalled)

        controller.dismiss()
        #expect(controller.rightClickInstalled)

        controller.present(menu, placement: .pointer(.zero))
        #expect(controller.isShowingMenu)
        #expect(controller.rightClickInstalled)
    }

    @Test func rightClickHitsTheFrontShellAndNotTheOneStackedBehindIt() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let shell = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        let hiddenHost = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        hiddenHost.alphaValue = 0
        let hidden = NSView(frame: hiddenHost.bounds)
        hiddenHost.addSubview(hidden)
        let files = NSView(frame: NSRect(x: 0, y: 100, width: 120, height: 28))
        content.addSubview(shell)
        content.addSubview(hiddenHost)
        content.addSubview(files)

        let shellMenu = MenuController()
        let hiddenMenu = MenuController()
        let fileMenu = MenuController()
        shellMenu.attachChip(to: shell)
        hiddenMenu.attachChip(to: hidden)
        fileMenu.attachChip(to: files)
        shellMenu.installTrigger {}
        hiddenMenu.installTrigger {}
        fileMenu.installTrigger {}
        defer {
            shellMenu.teardown()
            hiddenMenu.teardown()
            fileMenu.teardown()
            window.close()
        }

        let onFile = rightClick(files.convert(NSPoint(x: 12, y: 10), to: nil), in: window)
        #expect(fileMenu.claims(onFile))
        #expect(!shellMenu.claims(onFile))
        #expect(!hiddenMenu.claims(onFile))

        let onShell = rightClick(shell.convert(NSPoint(x: 200, y: 30), to: nil), in: window)
        #expect(shellMenu.claims(onShell))
        #expect(!fileMenu.claims(onShell))
        #expect(!hiddenMenu.claims(onShell))
    }

    @Test func rightClickOnStackedSwiftUIShellsOpensOnlyTheVisibleRow() throws {
        let back = MenuController()
        let front = MenuController()
        let files = MenuController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: StackedMenus(back: back, front: front, files: files))
        host.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(host)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        back.installTrigger {}
        front.installTrigger {}
        files.installTrigger {}
        defer {
            back.teardown()
            front.teardown()
            files.teardown()
            window.close()
        }

        let fileFrame = try #require(files.anchorFrameInWindow)
        let frontFrame = try #require(front.anchorFrameInWindow)
        let onFile = rightClick(NSPoint(x: fileFrame.midX, y: fileFrame.midY), in: window)
        #expect(files.claims(onFile))
        #expect(!back.claims(onFile))
        #expect(!front.claims(onFile))

        let onFront = rightClick(NSPoint(x: frontFrame.midX, y: frontFrame.midY), in: window)
        #expect(front.claims(onFront))
        #expect(!back.claims(onFront))
        #expect(!files.claims(onFront))
    }
}

private struct StackedMenus: View {
    let back: MenuController
    let front: MenuController
    let files: MenuController

    var body: some View {
        ZStack {
            row("back", controller: back)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .opacity(0)
                .allowsHitTesting(false)
                .zIndex(0)
            HStack(spacing: 0) {
                row("file", controller: files)
                    .frame(width: 120)
                row("front", controller: front)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .zIndex(1)
        }
        .frame(width: 320, height: 140)
    }

    private func row(_ title: String, controller: MenuController) -> some View {
        Text(title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(MenuProbe(controller: controller))
    }
}

private struct MenuProbe: NSViewRepresentable {
    let controller: MenuController

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        controller.attachChip(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        controller.attachChip(to: view)
    }
}

private func rightClick(_ point: NSPoint, in window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(
        with: .rightMouseDown,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )!
}
