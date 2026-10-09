import { afterEach, expect, it, vi } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createServer } from "../src/server";
const cleanup: (() => unknown)[] = [];
afterEach(async () => { for (const close of cleanup.splice(0)) await close(); });
async function connect() {
  const backend = {
    call: vi.fn(async (_name: string, _args: unknown, _signal?: AbortSignal) => ({ sessionId: "fixture", revision: 1 })),
    close: vi.fn(async () => {}),
  };
  const server = createServer(backend);
  const client = new Client({ name: "test", version: "1" });
  const [a, b] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(a), client.connect(b)]);
  cleanup.push(() => client.close(), () => server.close());
  return { client, backend };
}
it("negotiates MCP and forwards validated native tools without owning chess state", async () => {
  const { client, backend } = await connect();
  expect((await client.listTools()).tools).toHaveLength(23);
  const result = await client.callTool({ name: "get_session", arguments: {} });
  expect(result.isError).toBe(false);
  expect(result.structuredContent).toMatchObject({ sessionId: "fixture", revision: 1 });
  expect(backend.call).toHaveBeenCalledWith("get_session", {}, expect.any(AbortSignal));
});
it("rejects extra fields before contacting the native broker", async () => {
  const { client, backend } = await connect();
  const result = await client.callTool({ name: "play_move", arguments: { sessionId: "fixture", revision: 1, requestId: "extra", from: "e2", to: "e4" } });
  expect(result.isError).toBe(true);
  expect(backend.call).not.toHaveBeenCalled();
});
it("propagates host cancellation to the native broker request", async () => {
  const { client, backend } = await connect();
  let abortSeen = false;
  let started!: () => void;
  const readiness = new Promise<void>((resolve) => { started = resolve; });
  backend.call.mockImplementation(async (_name, _args, signal) => new Promise((resolve) => {
    signal!.addEventListener("abort", () => { abortSeen = true; resolve({ error: { code: "CANCELLED" } } as any); }, { once: true });
    started();
  }));
  const controller = new AbortController();
  const waiting = client.callTool({ name: "wait_for_change", arguments: { sessionId: "fixture", cursor: 1, timeoutMs: 20000 } }, undefined, { signal: controller.signal });
  const rejection = expect(waiting).rejects.toBeTruthy();
  await readiness;
  controller.abort();
  await rejection;
  await vi.waitFor(() => expect(abortSeen).toBe(true));
});
it("lists tools over the built stdio CLI outside the checkout", async () => {
  const { StdioClientTransport } = await import("@modelcontextprotocol/sdk/client/stdio.js");
  const { fileURLToPath } = await import("node:url");
  const { tmpdir } = await import("node:os");
  const transport = new StdioClientTransport({ command: process.execPath, args: [fileURLToPath(new URL("../dist/packages/companion-mcp/src/cli.js", import.meta.url))], cwd: tmpdir(), stderr: "pipe" });
  const client = new Client({ name: "stdio-test", version: "1" });
  await client.connect(transport);
  cleanup.push(() => client.close());
  expect((await client.listTools()).tools.map((tool) => tool.name)).toContain("wait_for_change");
});
