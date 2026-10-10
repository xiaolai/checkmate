import Foundation
import Darwin
import CoreFoundation
import CheckmateCore

/// Only the app-owned, private loopback endpoint is accepted. Never follow redirects.
public struct Discovery: Sendable {
    public let endpoint: URL
    public let authorizationNonce: String
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ai.xiaolai.checkmate/companion/connection.json")
    }
    public static func read(_ file: URL) throws -> Discovery {
        var directoryStat = stat()
        guard lstat(file.deletingLastPathComponent().path, &directoryStat) == 0,
              directoryStat.st_mode & S_IFMT == S_IFDIR,
              directoryStat.st_mode & 0o077 == 0, directoryStat.st_uid == getuid() else {
            throw ProtocolFailure("APP_NOT_READY")
        }
        // O_NOFOLLOW plus fstat avoids accepting a file swapped to a symlink.
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ProtocolFailure("APP_NOT_READY") }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o077 == 0, metadata.st_uid == getuid(),
              metadata.st_size > 0, metadata.st_size <= 4096 else { throw ProtocolFailure("APP_NOT_READY") }
        var bytes = [UInt8](repeating: 0, count: 4097)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count > 0, count <= 4096,
              let object = try JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any] else { throw ProtocolFailure("APP_NOT_READY") }
        guard let version = object["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1 else { throw ProtocolFailure("INCOMPATIBLE_SCHEMA") }
        guard let nonce = object["token"] as? String, nonce.utf8.count == 64, nonce.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let address = object["url"] as? String,
              address.range(of: "^http://127\\.0\\.0\\.1:[0-9]+$", options: .regularExpression) != nil,
              let url = URL(string: address), let port = url.port, (1...65535).contains(port) else { throw ProtocolFailure("APP_NOT_READY") }
        return Discovery(endpoint: url, authorizationNonce: nonce)
    }
}
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public actor BrokerClient {
    private let file: URL, clientID = UUID().uuidString
    private let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    private var discovery: Discovery?
    private var heartbeat: Task<Void, Never>?
    private var closed = false
    public init(connectionFile: URL = Discovery.defaultURL) { file = connectionFile }
    private func send(_ path: String, body: [String: Any], discovery: Discovery, timeout: TimeInterval = 3) async throws -> [String: Any] {
        var request = URLRequest(url: discovery.endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"; request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + discovery.authorizationNonce, forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "x-checkmate-client")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, !(300...399).contains(http.statusCode), data.count <= 131072,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProtocolFailure("CONNECTION_LOST") }
        return result
    }
    public func call(_ method: String, args: [String: Any]) async -> [String: Any] {
        guard !closed else { return ProtocolFailure("DISCONNECTED", "Start a new companion connection.").result }
        let current: Discovery
        do { current = try Discovery.read(file); discovery = current }
        catch { return ProtocolFailure((error as? ProtocolFailure)?.code ?? "APP_NOT_READY", "Open Checkmate and enable chess MCP connections in Settings.").result }
        let requestID = UUID().uuidString
        do {
            let result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await send("rpc", body: ["id": requestID, "method": method, "args": args], discovery: current, timeout: 25)
            } onCancel: {
                Task.detached { await self.cancel(requestID, discovery: current) }
            }
            if result["error"] == nil && heartbeat == nil && !closed {
                heartbeat = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(10)); try Task.checkCancellation() } catch { break }
                        guard let self, await self.pulse() else { break }
                    }
                }
            }
            return result
        } catch {
            return ProtocolFailure(Task.isCancelled ? "CANCELLED" : "CONNECTION_LOST", "Read the current session before retrying. A timed-out move may already have completed; reuse its requestId.").result
        }
    }
    private func cancel(_ id: String, discovery: Discovery) async { _ = try? await send("cancel", body: ["id": id], discovery: discovery) }
    private func pulse() async -> Bool {
        guard !closed, let current = discovery else { return false }
        do { let result = try await send("heartbeat", body: [:], discovery: current); if result["error"] == nil { return true } } catch {}
        heartbeat = nil; return false
    }
    public func close() async {
        guard !closed else { return }; closed = true
        heartbeat?.cancel(); heartbeat = nil
        if let current = discovery { _ = try? await send("disconnect", body: [:], discovery: current) }
        session.invalidateAndCancel()
    }
}
