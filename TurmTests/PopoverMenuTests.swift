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
}
