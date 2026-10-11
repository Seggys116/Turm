import Foundation

public nonisolated struct WorkspaceStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    private var layoutURL: URL { root.appendingPathComponent("layout.json") }
    private var blocksDirectory: URL { root.appendingPathComponent("blocks") }
    private var phoneURL: URL { root.appendingPathComponent("phone.json") }

    private func blockURL(for pane: UUID) -> URL {
        blocksDirectory.appendingPathComponent(pane.uuidString + ".json")
    }

    private func protectFile(at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var fileValues = URLResourceValues()
        fileValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(fileValues)
        protectRoot()
    }

    private func protectRoot() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        var rootValues = URLResourceValues()
        rootValues.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(rootValues)
    }

    public func save(_ document: WorkspaceDocument) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(document)
        try data.write(to: layoutURL, options: .atomic)
        try protectFile(at: layoutURL)
    }

    public func load() throws -> WorkspaceDocument? {
        guard FileManager.default.fileExists(atPath: layoutURL.path) else { return nil }
        let data = try Data(contentsOf: layoutURL)
        return try JSONDecoder().decode(WorkspaceDocument.self, from: data)
    }

    public func save(_ blocks: [SavedBlock], for pane: UUID) throws {
        try FileManager.default.createDirectory(at: blocksDirectory, withIntermediateDirectories: true)
        let retained = BlockArchive.retain(blocks)
        let data = try JSONEncoder().encode(retained)
        let url = blockURL(for: pane)
        try data.write(to: url, options: .atomic)
        try protectFile(at: url)
    }

    public func loadBlocks(for pane: UUID) -> [SavedBlock] {
        let url = blockURL(for: pane)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let blocks = try? JSONDecoder().decode([SavedBlock].self, from: data)
        else { return [] }
        return blocks
    }

    public func save(_ phone: PhoneWorkspace) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(phone)
        try data.write(to: phoneURL, options: .atomic)
        try protectFile(at: phoneURL)
    }

    public func loadPhone() throws -> PhoneWorkspace? {
        guard FileManager.default.fileExists(atPath: phoneURL.path) else { return nil }
        let data = try Data(contentsOf: phoneURL)
        return try JSONDecoder().decode(PhoneWorkspace.self, from: data)
    }

    public func removeWindow(_ id: UUID) throws {
        guard let document = try load() else { return }
        try save(document.removingWindow(id))
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }
}
