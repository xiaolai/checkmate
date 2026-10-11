import XCTest
import Foundation
import Darwin
import CheckmateCore
@testable import CheckmateMCPKit

/// A loopback stand-in for the broker that sends an oversized `/rpc` reply and then keeps the connection open, as a
/// misbehaving or hostile peer would. A client that buffers the whole reply before checking its size waits here.
private final class EndlessReplyServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32, declaredLength: Int?
    private let lock = NSLock()
    private var stopped = false
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    init(declaredLength: Int?) throws {
        self.declaredLength = declaredLength
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }) == 0, listen(fd, 16) == 0,
              withUnsafeMutablePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        listener = fd; port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in while true { let client = accept(listener, nil, nil); guard client >= 0 else { return }; Thread.detachNewThread { self.serve(client) } } }
    }
    private func send(_ client: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in var sent = 0; while sent < raw.count { let n = write(client, raw.baseAddress! + sent, raw.count - sent); if n <= 0 { return false }; sent += n }; return true }
    }
    private func serve(_ client: Int32) {
        defer { close(client) }
        // The client cancels mid-reply; a write to its closed socket must fail, not kill the test process.
        var yes: Int32 = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var request = Data(), chunk = [UInt8](repeating: 0, count: 65536)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil { let n = read(client, &chunk, chunk.count); if n <= 0 { return }; request.append(contentsOf: chunk[0..<n]) }
        guard request.starts(with: Data("POST /rpc ".utf8)) else { _ = send(client, Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}".utf8)); return }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n" + (declaredLength.map { "Content-Length: \($0)\r\n" } ?? "") + "\r\n"
        guard send(client, Data(header.utf8)), send(client, Data("{\"pad\":\"".utf8)), send(client, Data(repeating: UInt8(ascii: "a"), count: 3 * 1024 * 1024)) else { return }
        // Never finish the reply; hold the connection until the client gives up or the test ends.
        for _ in 0..<400 where !isStopped { usleep(100_000) }
    }
    func stop() { lock.lock(); stopped = true; lock.unlock(); shutdown(listener, SHUT_RDWR); close(listener) }
}

/// Audit #11: the response bound must stop the read, not be checked after the whole reply has been buffered.
final class CompanionFixBrokerStreamingTests: XCTestCase {
    private func call(declaredLength: Int?) async throws -> (code: String?, seconds: Double) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let server = try EndlessReplyServer(declaredLength: declaredLength), file = directory.appendingPathComponent("connection.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "token": String(repeating: "a", count: 64), "url": "http://127.0.0.1:\(server.port)"]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let client = BrokerClient(connectionFile: file), start = Date()
        let result = await client.call("get_review", args: [:]), seconds = Date().timeIntervalSince(start)
        await client.close(); server.stop(); try? FileManager.default.removeItem(at: directory)
        return (((result["error"] as? [String: Any])?["code"] as? String), seconds)
    }
    func testAnOversizedReplyWithoutALengthIsCutOffWhileStreaming() async throws {
        let (code, seconds) = try await call(declaredLength: nil)
        XCTAssertEqual(code, "RESPONSE_TOO_LARGE", "Reading stops at the bound instead of waiting for the reply to end")
        XCTAssertLessThan(seconds, 10, "The client does not wait for the rest of an oversized reply")
    }
    func testAnOversizedDeclaredLengthIsRefusedBeforeTheBodyIsRead() async throws {
        let (code, seconds) = try await call(declaredLength: 1 << 30)
        XCTAssertEqual(code, "RESPONSE_TOO_LARGE")
        XCTAssertLessThan(seconds, 10)
    }
}
