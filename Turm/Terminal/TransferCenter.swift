import Observation
import SwiftUI
import TurmCore

@MainActor
@Observable
final class TransferCenter {
    static let shared = TransferCenter()

    private(set) var items: [Job] = []
    var hovering = false

    @Observable
    final class Job: Identifiable {
        let id = UUID()
        let name: String
        var transferred: Int64 = 0
        var total: Int64 = 0
        var speed: Double = 0
        var state: State = .running
        fileprivate let flag = CancelFlag()
        fileprivate var sampleBytes: Int64 = 0
        fileprivate var sampleTime = Date()

        init(name: String) { self.name = name }

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(Double(transferred) / Double(total), 1)
        }

        func cancel() { flag.cancel() }
    }

    enum State: Equatable {
        case running, finished, failed, cancelled
    }

    func copy(_ urls: [URL], into directory: String, move: Bool) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            for url in urls {
                let job = start(url.lastPathComponent)
                let flag = job.flag
                let id = job.id
                group.addTask {
                    do {
                        try await Task.detached {
                            let destination = URL(fileURLWithPath: FileDrop.destination(
                                named: url.lastPathComponent,
                                into: directory,
                                existing: Set((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
                            ))
                            try FileCopy.transfer(from: url, to: destination, move: move, isCancelled: { flag.isCancelled }) { sent, size in
                                TransferCenter.report(id, sent, size)
                            }
                        }.value
                        await MainActor.run { TransferCenter.shared.finish(id) }
                        return nil
                    } catch {
                        await MainActor.run { TransferCenter.shared.fail(id, error) }
                        return error.localizedDescription
                    }
                }
            }
            return await Self.firstFailure(of: group)
        }
    }

    func upload(_ channel: RemoteChannel, _ urls: [URL], into directory: String) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            for url in urls {
                let job = start(url.lastPathComponent)
                let flag = job.flag
                let id = job.id
                group.addTask {
                    let sent = await channel.upload(url, into: directory, isCancelled: { flag.isCancelled }) { amount, size in
                        TransferCenter.report(id, amount, size)
                    }
                    if sent != nil {
                        await MainActor.run { TransferCenter.shared.finish(id) }
                        return nil
                    }
                    await MainActor.run {
                        TransferCenter.shared.fail(id, flag.isCancelled ? FileDropError.cancelled : FileTransferError.disconnected)
                    }
                    return flag.isCancelled ? nil : "Could not send \(url.lastPathComponent)."
                }
            }
            return await Self.firstFailure(of: group)
        }
    }

    func upload(_ channel: RemoteChannel, _ urls: [URL]) async -> [URL: String] {
        await withTaskGroup(of: (URL, String)?.self) { group in
            for url in urls {
                let job = start(url.lastPathComponent)
                let flag = job.flag
                let id = job.id
                group.addTask {
                    let path = await channel.uploadTracked(url, isCancelled: { flag.isCancelled }) { sent, size in
                        TransferCenter.report(id, sent, size)
                    }
                    if let path {
                        await MainActor.run { TransferCenter.shared.finish(id) }
                        return (url, path)
                    }
                    await MainActor.run { TransferCenter.shared.fail(id, FileDropError.cancelled) }
                    return nil
                }
            }
            var paths: [URL: String] = [:]
            for await pair in group {
                if let pair { paths[pair.0] = pair.1 }
            }
            return paths
        }
    }

    private func start(_ name: String) -> Job {
        let job = Job(name: name)
        items.append(job)
        return job
    }

    private func finish(_ id: UUID) {
        items.first { $0.id == id }?.complete()
    }

    private func fail(_ id: UUID, _ error: Error) {
        items.first { $0.id == id }?.fail(error)
    }

    nonisolated static func report(_ id: UUID, _ sent: Int64, _ size: Int64) {
        Task { @MainActor in
            shared.items.first { $0.id == id }?.note(sent, size)
        }
    }

    private static func firstFailure(of group: TaskGroup<String?>) async -> String? {
        var failure: String?
        for await result in group {
            if let result { failure = result }
        }
        return failure
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

extension TransferCenter.Job {
    fileprivate func note(_ sent: Int64, _ size: Int64) {
        transferred = sent
        if size > 0 { total = size }
        let now = Date()
        let elapsed = now.timeIntervalSince(sampleTime)
        if elapsed >= 0.3 {
            speed = Double(sent - sampleBytes) / elapsed
            sampleBytes = sent
            sampleTime = now
        }
    }

    fileprivate func complete() {
        state = flag.isCancelled ? .cancelled : .finished
        scheduleRemoval()
    }

    fileprivate func fail(_ error: Error) {
        if flag.isCancelled || (error as? FileDropError) == .cancelled {
            state = .cancelled
        } else {
            state = .failed
        }
        scheduleRemoval()
    }

    private func scheduleRemoval() {
        let id = id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            while TransferCenter.shared.hovering {
                try? await Task.sleep(for: .milliseconds(200))
            }
            TransferCenter.shared.items.removeAll { $0.id == id && $0.state != .running }
        }
    }
}

struct TransferStack: View {
    var center = TransferCenter.shared
    @State private var expanded = false

    var body: some View {
        let items = center.items
        Group {
            if items.isEmpty {
                EmptyView()
            } else if expanded {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(items) { job in TransferCard(job: job) }
                }
            } else {
                ZStack(alignment: .bottomTrailing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, job in
                        let depth = items.count - 1 - index
                        TransferCard(job: job)
                            .scaleEffect(depth == 0 ? 1 : 0.97, anchor: .bottomTrailing)
                            .offset(y: CGFloat(depth) * -8)
                            .zIndex(Double(index))
                    }
                }
                .frame(height: 72, alignment: .bottom)
            }
        }
        .shadow(color: .black.opacity(0.28), radius: expanded ? 10 : 6, y: 3)
        .onHover { inside in
            expanded = inside
            center.hovering = inside
        }
        .animation(.easeOut(duration: 0.16), value: expanded)
        .animation(.easeOut(duration: 0.16), value: items.map(\.id))
    }
}

private struct TransferCard: View {
    let job: TransferCenter.Job

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(job.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if job.state == .running {
                    Button(action: job.cancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText.color)
                    .help("Cancel")
                }
            }
            progress
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.secondaryText.color)
        }
        .padding(10)
        .frame(width: 260, alignment: .leading)
        .background(Theme.inputBackground.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.chipStroke.color, lineWidth: 1))
    }

    private var progress: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.chipFill.color)
                Capsule()
                    .fill(job.state == .failed ? Theme.removed.color : Theme.added.color)
                    .frame(width: proxy.size.width * job.fraction)
            }
        }
        .frame(height: 4)
    }

    private var detail: String {
        switch job.state {
        case .running:
            let percent = Int((job.fraction * 100).rounded())
            return "\(percent)%  \(TransferFormat.rate(job.speed))"
        case .finished: return "Finished"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

enum TransferFormat {
    static func rate(_ bytes: Double) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.0f KB/s", bytes / 1_000) }
        return String(format: "%.0f B/s", max(bytes, 0))
    }
}
