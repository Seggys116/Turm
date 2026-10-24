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

/// System toolbar controls for the open session. The navigation bar draws them.
struct SessionToolbar: View {
    let workspace: Workspace
    let tab: any TerminalTab

    var body: some View {
        if let surface = keyboardSurface {
            Button("Keyboard", systemImage: "keyboard") {
                _ = surface.becomeFirstResponder()
            }
        }
        Menu("Session", systemImage: "ellipsis") {
            sessionMenu
        }
    }

    private var keyboardSurface: UIView? {
        if let ssh = tab as? SSHTerminalSession, !ssh.usesBlocks { return ssh.surface.view }
        if let blocks = tab as? any BlockSession { return blocks.fullScreen?.view }
        return nil
    }

    @ViewBuilder
    private var sessionMenu: some View {
        Button("New Session", systemImage: "plus") { workspace.showsHostPicker = true }
        if let mac = tab as? MacSession {
            Divider()
            Button(mac.fitsDevice ? "Use Mac Size" : "Fit to This Device") { mac.setFitsDevice(!mac.fitsDevice) }
            if mac.macColumns > 0 {
                Text("Mac size \(mac.macColumns) by \(mac.macRows)")
            }
        }
        if !workspace.windowMenuItems(for: tab).isEmpty {
            Divider()
        }
        ForEach(workspace.windowMenuItems(for: tab)) { item in
            Button(item.title, systemImage: item.systemImage ?? "macwindow") { item.action() }
        }
        Divider()
        Button("Close Session", systemImage: "xmark", role: .destructive) { workspace.close(tab) }
    }
}

/// The buttons that act on the open session: the software keyboard, and the session menu.
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
                ChromeMenuItem(title: "Fit to This Device", isOn: mac.fitsDevice) { mac.setFitsDevice(!mac.fitsDevice) }
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
