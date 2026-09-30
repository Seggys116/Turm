import Foundation
import Observation

nonisolated struct ActionProgress: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case running
        case succeeded
        case failed
    }

    static let successHold: TimeInterval = 0.8
    static let fade: TimeInterval = 0.6
    static let pulseDuration: TimeInterval = 8

    var startedAt: Date
    var outcome = Outcome.running
    var finishedAt: Date?

    func successOpacity(at date: Date) -> Double {
        guard let finishedAt, outcome == .succeeded else { return 0 }
        let since = date.timeIntervalSince(finishedAt) - Self.successHold
        return since <= 0 ? 1 : max(1 - since / Self.fade, 0)
    }

    func isSettled(at date: Date) -> Bool {
        guard let finishedAt, outcome == .succeeded else { return false }
        return date.timeIntervalSince(finishedAt) > Self.successHold + Self.fade
    }

    func pulse(at date: Date) -> Double {
        guard outcome == .failed, let finishedAt else { return 0 }
        if date.timeIntervalSince(finishedAt) > Self.pulseDuration { return 0.35 }
        return 0.5 + 0.5 * sin(date.timeIntervalSinceReferenceDate * 4.4)
    }
}

@Observable
final class ActionRunner {
    private(set) var action: ProjectAction?
    private(set) var command: String?
    private(set) var progress: ActionProgress?
    private(set) var exitCode: Int32?
    private(set) var session: TerminalSession?
    private(set) var isAcknowledged = false
    var isWatching = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID = 0

    var isRunning: Bool { progress?.outcome == .running }
    var isActive: Bool { session != nil }

    var isInteractive: Bool { session?.altScreen != nil }

    var activity: ShellActivity {
        switch progress?.outcome {
        case .running: session.map { $0.activity.isBusy ? $0.activity : .working } ?? .working
        case .succeeded: isAcknowledged ? .inactive : .succeeded
        case .failed: isAcknowledged ? .inactive : .failed
        case nil: .inactive
        }
    }

    func acknowledge() {
        guard let outcome = progress?.outcome, outcome != .running, !isAcknowledged else { return }
        isAcknowledged = true
    }

    func start(_ action: ProjectAction, command: String) {
        dismiss()
        let sub = TerminalSession(directory: action.root, auxiliary: true)
        session = sub
        self.action = action
        self.command = command
        exitCode = nil
        isAcknowledged = false
        progress = ActionProgress(startedAt: .now)
        runID += 1
        let run = runID
        task = Task { [weak self, weak sub] in
            guard let sub else { return }
            await self?.drive(sub, command: command, run: run)
        }
    }

    func stop() {
        session?.interrupt()
    }

    func dismiss() {
        task?.cancel()
        task = nil
        session?.terminate()
        session = nil
        action = nil
        command = nil
        progress = nil
        exitCode = nil
        isWatching = false
    }

    func release() -> TerminalSession? {
        guard let released = session else { return nil }
        task?.cancel()
        task = nil
        session = nil
        action = nil
        command = nil
        progress = nil
        exitCode = nil
        isWatching = false
        return released
    }

    private func drive(_ sub: TerminalSession, command: String, run: Int) async {
        var waited = 0
        while sub.phase == .starting {
            guard sub.isOpen, waited < 400 else { return conclude(run, code: nil, failed: true) }
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
            if Task.isCancelled { return }
        }
        sub.submit(command)
        guard sub.phase == .submitted else { return conclude(run, code: nil, failed: true) }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(60))
            if Task.isCancelled { return }
            if !sub.isOpen { return conclude(run, code: nil, failed: true) }
            if sub.phase == .ready {
                let code = sub.blocks.last?.exitCode
                return conclude(run, code: code, failed: (code ?? 0) != 0)
            }
        }
    }

    private func conclude(_ run: Int, code: Int32?, failed: Bool) {
        guard run == runID, var current = progress, current.outcome == .running else { return }
        current.finishedAt = .now
        current.outcome = failed ? .failed : .succeeded
        progress = current
        exitCode = code
    }
}
