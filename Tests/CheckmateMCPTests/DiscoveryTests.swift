import XCTest
import Foundation
import CheckmateCore
@testable import CheckmateMCPKit

final class DiscoveryTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func write(address: String = "http://127.0.0.1:54321", version: Int = 1) throws -> URL {
        let file = directory.appendingPathComponent("connection.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": version, "token": String(repeating: "a", count: 64), "url": address]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }
    func testPrivateLoopbackDiscovery() throws { XCTAssertEqual(try Discovery.read(write()).endpoint.port, 54321) }
    func testRejectsNonLoopbackAndMalformedEndpoints() throws {
        for url in ["https://127.0.0.1:54321", "http://localhost:54321", "http://example.com:54321", "http://127.0.0.1:0", "http://127.0.0.1:65536", "http://127.0.0.1:54321/rpc", "http://127.0.0.1:54321?x=1"] {
            XCTAssertThrowsError(try Discovery.read(write(address: url)), url)
        }
    }
    func testRejectsPublicFileAndDirectory() throws {
        let file = try write()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try Discovery.read(file))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try Discovery.read(file))
    }
    func testRejectsSymlinkFileAndDirectory() throws {
        let file = try write(), link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try Discovery.read(link))
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertThrowsError(try Discovery.read(alias.appendingPathComponent("connection.json")))
    }
    func testRejectsOversizeAndIncompatibleSchema() throws {
        let file = try write(version: 2)
        XCTAssertThrowsError(try Discovery.read(file)) { XCTAssertEqual(($0 as? ProtocolFailure)?.code, "INCOMPATIBLE_SCHEMA") }
        try Data(repeating: 65, count: 4097).write(to: file)
        XCTAssertThrowsError(try Discovery.read(file))
    }
    func testRejectsBooleanVersionAndMalformedNonce() throws {
        let file = try write()
        for fields in [["schemaVersion": true, "token": String(repeating: "a", count: 64)], ["schemaVersion": 1, "token": String(repeating: "a", count: 64) + "\n"]] as [[String: Any]] {
            var data = fields; data["url"] = "http://127.0.0.1:54321"
            try JSONSerialization.data(withJSONObject: data).write(to: file)
            XCTAssertThrowsError(try Discovery.read(file))
        }
    }
    func testMissingAppAndClosedConnectionAreStructuredErrors() async throws {
        let client = BrokerClient(connectionFile: directory.appendingPathComponent("missing.json"))
        let absent = await client.call("get_session", args: [:])
        XCTAssertEqual((absent["error"] as? [String: Any])?["code"] as? String, "APP_NOT_READY")
        await client.close()
        let closed = await client.call("get_session", args: [:])
        XCTAssertEqual((closed["error"] as? [String: Any])?["code"] as? String, "DISCONNECTED")
    }
}
