import Foundation
import CheckmateCore
import MCP
import Darwin

public enum CompanionServer {
    public static func make(client: BrokerClient) async throws -> Server {
        let schemas = try ToolSchemas()
        let definitions = try JSONSerialization.jsonObject(with: Data(contentsOf: NativeResources.url("tool-schemas.json"))) as! [String: [String: Any]]
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: NativeResources.url("mcp-tools.json"))) as! [String: [String: Any]]
        let tools = try schemas.names.map { name -> Tool in
            guard let info = metadata[name], let description = info["description"] as? String else { throw ProtocolFailure("INCOMPATIBLE_SCHEMA") }
            let schema = try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: definitions[name]!))
            return Tool(name: name, description: description, inputSchema: schema,
                        annotations: .init(readOnlyHint: info["readOnly"] as? Bool, destructiveHint: false, openWorldHint: false))
        }
        let server = Server(name: "checkmate-companion", version: "0.3.1",
                            instructions: try String(contentsOf: NativeResources.url("mcp-instructions.txt"), encoding: .utf8),
                            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in
            let result: [String: Any]
            do {
                let data = try JSONEncoder().encode(params.arguments ?? [:])
                let args = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let parsed = try schemas.parse(params.name, args: args)
                result = await client.call(params.name, args: parsed)
            } catch { result = (error as? ProtocolFailure ?? ProtocolFailure("INVALID_ARGUMENT")).result }
            let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            return try .init(content: [.text(text: String(decoding: encoded, as: UTF8.self), annotations: nil, _meta: nil)],
                         structuredContent: try JSONDecoder().decode(Value.self, from: encoded), isError: result["error"] != nil)
        }
        return server
    }
    public static func run(connectionFile: URL = Discovery.defaultURL) async throws {
        let client = BrokerClient(connectionFile: connectionFile)
        do {
            let server = try await make(client: client)
            try await server.start(transport: StdioTransport())
            let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { Task { await server.stop() } }
                source.resume()
                return source
            }
            defer { signals.forEach { $0.cancel() } }
            await server.waitUntilCompleted()
            await server.stop()
            await client.close()
        } catch { await client.close(); throw error }
    }
}
