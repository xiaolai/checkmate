import XCTest
import Foundation
import Darwin
import CheckmateCore
@testable import CheckmateMCPKit

/// A loopback HTTP/1.1 stand-in for the app's broker: every `/rpc` reply is a JSON object of exactly `size` bytes.
private final class SizedReplyServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var replyBytes = 0
    var size: Int { get { lock.lock(); defer { lock.unlock() }; return replyBytes } set { lock.lock(); replyBytes = newValue; lock.unlock() } }
    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }) == 0, listen(fd, 16) == 0,
              withUnsafeMutablePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        listener = fd; port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in while true { let client = accept(listener, nil, nil); guard client >= 0 else { return }; serve(client) } }
    }
    static func body(_ size: Int) -> Data { Data(("{\"pad\":\"" + String(repeating: "a", count: size - 10) + "\"}").utf8) }
    private func serve(_ client: Int32) {
        defer { close(client) }
        // The client stops reading an oversized reply; a write to its closed socket must fail, not kill the test process.
        var yes: Int32 = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var request = Data(), chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let end = request.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: request[..<end.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }.flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if request.count - end.upperBound >= length {
                    let reply = head.hasPrefix("POST /rpc ") ? Self.body(size) : Data("{}".utf8)
                    var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(reply.count)\r\n\r\n".utf8); response.append(reply)
                    response.withUnsafeBytes { raw in var sent = 0; while sent < raw.count { let n = write(client, raw.baseAddress! + sent, raw.count - sent); if n <= 0 { return }; sent += n } }
                    return
                }
            }
            let n = read(client, &chunk, chunk.count); if n <= 0 { return }; request.append(contentsOf: chunk[0..<n])
        }
    }
    func stop() { shutdown(listener, SHUT_RDWR); close(listener) }
}

/// VC2-6: a large but intact broker reply (an annotated review page) is delivered, not reported as CONNECTION_LOST; a
/// reply over the 2 MiB bound is refused as RESPONSE_TOO_LARGE with advice to ask for less, never buffered unbounded.
final class GapBrokerClientTests: XCTestCase {
    private var directory: URL!, server: SizedReplyServer!, client: BrokerClient!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        server = try SizedReplyServer()
        let file = directory.appendingPathComponent("connection.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "token": String(repeating: "a", count: 64), "url": "http://127.0.0.1:\(server.port)"]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        client = BrokerClient(connectionFile: file)
    }
    override func tearDown() async throws { await client.close(); server.stop(); try? FileManager.default.removeItem(at: directory) }
    private func code(_ result: [String: Any]) -> String? { (result["error"] as? [String: Any])?["code"] as? String }

    func testAReplyOverTheOldLimitIsDeliveredIntact() async throws {
        server.size = 200 * 1024
        let result = await client.call("get_review", args: [:])
        XCTAssertNil(result["error"], "A 200 KB review page is not a lost connection")
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: result), SizedReplyServer.body(200 * 1024), "The page arrives byte-for-byte")
    }
    func testAReplyAtTheBoundIsDelivered() async throws {
        XCTAssertEqual(BrokerClient.maximumResponseBytes, 2 * 1024 * 1024)
        server.size = BrokerClient.maximumResponseBytes
        let result = await client.call("get_review", args: [:])
        XCTAssertNil(result["error"]); XCTAssertEqual((result["pad"] as? String)?.utf8.count, BrokerClient.maximumResponseBytes - 10)
    }
    func testAReplyOverTheBoundIsRefusedWithAdvice() async throws {
        server.size = BrokerClient.maximumResponseBytes + 1
        let result = await client.call("get_review", args: [:])
        XCTAssertEqual(code(result), "RESPONSE_TOO_LARGE", "Not CONNECTION_LOST, whose advice is to retry the same request")
        let message = (result["error"] as? [String: Any])?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("2048 KB") && message.contains("smaller page"), message)
        XCTAssertNil(result["pad"], "No part of the oversized reply is passed on")
    }
}
