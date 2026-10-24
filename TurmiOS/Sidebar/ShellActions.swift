import SwiftTerm
import SwiftUI
import TurmCore
import UIKit

/// The app-wide bar buttons, shared by the sidebar, the session detail and the iPhone Duo vertical bar.
struct NewMenuButton: View {
    let workspace: Workspace

    var body: some View {
        ChromeMenuButton(systemImage: "plus", label: "New") {
            [
                ChromeMenuItem(title: "New Session", systemImage: "terminal") { workspace.showsHostPicker = true },
                ChromeMenuItem(title: "New SSH Host", systemImage: "network") { workspace.editingHost = SSHHost(key: "", hostname: "") },
                ChromeMenuItem(title: "Pair a Mac", systemImage: "link") { workspace.showsPairing = true },
            ]
        }
    }
}

struct SettingsButton: View {
    let workspace: Workspace

    var body: some View {
        ChromeIconButton(systemImage: "gearshape", label: "Settings") { workspace.showsSettings = true }
    }
}

struct SidebarToggleButton: View {
    let workspace: Workspace

    var body: some View {
        ChromeIconButton(
            systemImage: "sidebar.left", label: workspace.sidebarHidden ? "Show Sidebar" : "Hide Sidebar"
        ) {
            workspace.sidebarHidden.toggle()
        }
    }
}

struct SessionsBackButton: View {
    let workspace: Workspace

    var body: some View {
        ChromeBackButton(label: "Sessions") { workspace.compactColumn = .sidebar }
    }
}

/// The buttons that act on the open session: the software keyboard, and the session menu.
///
/// These sit in the session strip. The navigation bar is hidden while a session is open, so this
/// menu is the one that offers fitting a Mac shell to the device or putting it back to the Mac's size.
struct SessionButtons: View {
    let workspace: Workspace
    let tab: any TerminalTab

    var body: some View {
        if let surface = keyboardSurface {
            ChromeIconButton(systemImage: "keyboard", label: "Keyboard") {
                _ = surface.becomeFirstResponder()
            }
        }
        ChromeMenuButton(systemImage: "ellipsis", label: "Session") { items }
    }

    private var keyboardSurface: UIView? {
        if let ssh = tab as? SSHTerminalSession, !ssh.usesBlocks { return ssh.surface.view }
        if let blocks = tab as? any BlockSession { return blocks.fullScreen?.view }
        return nil
    }

    private var items: [ChromeMenuItem] {
        var items = [ChromeMenuItem(title: "New Session", systemImage: "plus") { workspace.showsHostPicker = true }]
        if let mac = tab as? MacSession {
            items.append(
                ChromeMenuItem(title: mac.fitsDevice ? "Use Mac Size" : "Fit to This Device") {
                    mac.setFitsDevice(!mac.fitsDevice)
                }
                .separatedFromPrevious()
            )
            if mac.macColumns > 0 { items.append(.note("Mac size \(mac.macColumns) by \(mac.macRows)")) }
        }
        items += workspace.windowMenuItems(for: tab).map { $0.separatedFromPrevious() }
        items.append(
            ChromeMenuItem(title: "Close Session", systemImage: "xmark", role: .destructive) { workspace.close(tab) }
                .separatedFromPrevious()
        )
        return items
    }
}
