import CoreGraphics
import Foundation
import Observation
import TurmCore

enum BlockSessionBanner: Equatable {
    case progress(String)
    case problem(String, systemImage: String)
    case notice(String)
}

struct BlockSessionError: LocalizedError {
    let text: String

    var errorDescription: String? { text }
}

/// What the block list, input bar and chips need from a shell, whether it lives on a paired Mac or behind a direct SSH connection.
@MainActor
protocol BlockSession: AnyObject, Observable {
    var blocks: [MacBlock] { get }
    var runningBlock: MacBlock? { get }
    var commands: [String] { get }
    var fullScreen: TerminalSurface? { get }
    var phase: CompanionPhase { get }
    var acceptsInput: Bool { get }
    var banner: BlockSessionBanner? { get }
    var location: String { get }
    var directory: String { get }
    var branch: String? { get }
    var remoteLabel: String? { get }
    var editor: ShortcutTarget? { get set }
    var showsBranches: Bool { get set }

    func submit(_ text: String)
    func input(_ bytes: Data)
    func interrupt()
    func setViewport(_ size: CGSize, fontSize: Double)
    func changeDirectory(to path: String)
    func dismissNotice()

    var supportsShortcuts: Bool { get }
    var shortcuts: [Shortcut] { get }
    func commandShortcut(for command: String) -> Shortcut?
    func directoryShortcut(at path: String) -> Shortcut?
    func removeShortcut(_ shortcut: Shortcut)
    func shortcutInfo(for target: ShortcutTarget) async throws -> (existing: Shortcut?, draft: Shortcut)
    func save(_ shortcut: Shortcut) async throws
    func remove(_ shortcut: Shortcut) async throws

    var supportsBranches: Bool { get }
    func branches() async throws -> (names: [String], current: String?)
    func switchBranch(to name: String) async throws -> String?

    var revealTitle: String? { get }
    func reveal(_ path: String)
}

extension BlockSession {
    func dismissNotice() {}

    var supportsShortcuts: Bool { false }
    var shortcuts: [Shortcut] { [] }
    func commandShortcut(for command: String) -> Shortcut? { nil }
    func directoryShortcut(at path: String) -> Shortcut? { nil }
    func removeShortcut(_ shortcut: Shortcut) {}

    func shortcutInfo(for target: ShortcutTarget) async throws -> (existing: Shortcut?, draft: Shortcut) {
        throw BlockSessionError(text: "Shortcuts are not available in this session.")
    }

    func save(_ shortcut: Shortcut) async throws {
        throw BlockSessionError(text: "Shortcuts are not available in this session.")
    }

    func remove(_ shortcut: Shortcut) async throws {
        throw BlockSessionError(text: "Shortcuts are not available in this session.")
    }

    var supportsBranches: Bool { false }

    func branches() async throws -> (names: [String], current: String?) {
        throw BlockSessionError(text: "Branches are not available in this session.")
    }

    func switchBranch(to name: String) async throws -> String? {
        throw BlockSessionError(text: "Branches are not available in this session.")
    }

    var revealTitle: String? { nil }
    func reveal(_ path: String) {}
}
