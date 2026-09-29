import CryptoKit
import Foundation

nonisolated struct DockerImage: Equatable, Sendable {
    let id: String
    let names: [String]
}

nonisolated struct DockerContainer: Equatable, Sendable {
    let id: String
    let names: [String]
    let image: String
    let state: String
}

nonisolated struct DockerObjects: Equatable, Sendable {
    var images: [DockerImage] = []
    var containers: [DockerContainer] = []
    var volumes: [String] = []
    var networks: [String] = []
    var available = false
}

nonisolated enum DockerEngine {
    static func socketPath(
        variables: [String: String], home: String, readText: (String) -> String?, exists: (String) -> Bool
    ) -> String? {
        var candidates: [String] = []
        if let host = variables["DOCKER_HOST"] {
            guard host.hasPrefix("unix://") else { return nil }
            candidates.append(String(host.dropFirst("unix://".count)))
        } else if let host = contextHost(variables: variables, home: home, readText: readText) {
            guard host.hasPrefix("unix://") else { return nil }
            candidates.append(String(host.dropFirst("unix://".count)))
        }
        candidates += [home + "/.docker/run/docker.sock", home + "/.orbstack/run/docker.sock", "/var/run/docker.sock"]
        return candidates.first(where: exists)
    }

    static func contextHost(variables: [String: String], home: String, readText: (String) -> String?) -> String? {
        var name = variables["DOCKER_CONTEXT"]
        if name == nil, let config = readText(home + "/.docker/config.json"),
           let object = try? JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any] {
            name = object["currentContext"] as? String
        }
        guard let name, !name.isEmpty, name != "default" else { return nil }
        return hostOfContext(named: name, home: home, readText: readText)
    }

    static func hostOfContext(named name: String, home: String, readText: (String) -> String?) -> String? {
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let meta = readText(home + "/.docker/contexts/meta/\(digest)/meta.json"),
              let object = try? JSONSerialization.jsonObject(with: Data(meta.utf8)) as? [String: Any],
              let endpoints = object["Endpoints"] as? [String: Any],
              let docker = endpoints["docker"] as? [String: Any]
        else { return nil }
        return docker["Host"] as? String
    }

    static func contextSocket(variables: [String: String], home: String, readText: (String) -> String?) -> String? {
        guard let host = contextHost(variables: variables, home: home, readText: readText), host.hasPrefix("unix://") else { return nil }
        return String(host.dropFirst("unix://".count))
    }

    static func contextNames(home: String, entries: (String) -> [DirectoryEntry]?, readText: (String) -> String?) -> [String] {
        var names = ["default"]
        for entry in entries(home + "/.docker/contexts/meta") ?? [] where entry.isDirectory {
            guard let meta = readText(home + "/.docker/contexts/meta/\(entry.name)/meta.json"),
                  let object = try? JSONSerialization.jsonObject(with: Data(meta.utf8)) as? [String: Any],
                  let name = object["Name"] as? String
            else { continue }
            names.append(name)
        }
        return Array(Set(names)).sorted()
    }

    static func makeAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { target in
                for (index, byte) in bytes.enumerated() { target[index] = byte }
            }
        }
        return address
    }

    static func fetch(_ path: String, socket socketPath: String, timeout: TimeInterval = 1.5) -> Data? {
        guard var address = makeAddress(socketPath) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var interval = timeval(tv_sec: time_t(timeout), tv_usec: suseconds_t((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))

        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { return nil }
            var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return nil }
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length)
            guard failure == 0 else { return nil }
        }
        _ = fcntl(descriptor, F_SETFL, flags)

        let request = Array("GET \(path) HTTP/1.0\r\nHost: docker\r\nAccept: application/json\r\nConnection: close\r\n\r\n".utf8)
        var sent = 0
        while sent < request.count {
            let count = request.withUnsafeBytes { send(descriptor, $0.baseAddress! + sent, request.count - sent, 0) }
            guard count > 0 else { return nil }
            sent += count
        }

        var received = Data()
        let capacity = 65536
        var buffer = [UInt8](repeating: 0, count: capacity)
        while received.count < 16_000_000 {
            let count = recv(descriptor, &buffer, capacity, 0)
            if count <= 0 { break }
            received.append(buffer, count: count)
        }
        guard let response = decodeHTTP(received), response.status == 200 else { return nil }
        return response.body
    }

    static func decodeHTTP(_ raw: Data) -> (status: Int, body: Data)? {
        let separator = Data("\r\n\r\n".utf8)
        guard let split = raw.range(of: separator) else { return nil }
        let head = String(decoding: raw[..<split.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, let status = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
            return nil
        }
        let chunked = lines.dropFirst().contains { $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked") }
        let body = raw[split.upperBound...]
        return (status, chunked ? dechunk(Data(body)) : Data(body))
    }

    static func dechunk(_ data: Data) -> Data {
        var output = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while index < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { break }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
            let hex = sizeText.split(separator: ";").first.map(String.init) ?? sizeText
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            let end = min(start + size, data.endIndex)
            output.append(data[start..<end])
            index = min(end + 2, data.endIndex)
        }
        return output
    }

    static func parseImages(_ data: Data) -> [DockerImage] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let id = entry["Id"] as? String else { return nil }
            let tags = (entry["RepoTags"] as? [String] ?? []).filter { $0 != "<none>:<none>" }
            return DockerImage(id: shortID(id), names: tags)
        }
    }

    static func parseContainers(_ data: Data) -> [DockerContainer] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let id = entry["Id"] as? String else { return nil }
            let names = (entry["Names"] as? [String] ?? []).map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
            return DockerContainer(
                id: shortID(id),
                names: names,
                image: entry["Image"] as? String ?? "",
                state: entry["State"] as? String ?? ""
            )
        }
    }

    static func parseVolumes(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let volumes = object["Volumes"] as? [[String: Any]]
        else { return [] }
        return volumes.compactMap { $0["Name"] as? String }
    }

    static func parseNetworks(_ data: Data) -> [String] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { $0["Name"] as? String }
    }

    static func shortID(_ id: String) -> String {
        String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12))
    }

    static func load(socket: String, timeout: TimeInterval = 1.5) -> DockerObjects {
        var objects = DockerObjects()
        guard let images = fetch("/images/json", socket: socket, timeout: timeout) else { return objects }
        objects.images = parseImages(images)
        objects.available = true
        if let data = fetch("/containers/json?all=1", socket: socket, timeout: timeout) {
            objects.containers = parseContainers(data)
            objects.available = true
        }
        if let data = fetch("/volumes", socket: socket, timeout: timeout) {
            objects.volumes = parseVolumes(data)
            objects.available = true
        }
        if let data = fetch("/networks", socket: socket, timeout: timeout) {
            objects.networks = parseNetworks(data)
            objects.available = true
        }
        return objects
    }
}
