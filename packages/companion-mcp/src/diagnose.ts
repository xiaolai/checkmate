#!/usr/bin/env node
// A fixed read-only diagnostic. The host should use its persistent MCP connection for play.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { fileURLToPath } from "node:url";
const client = new Client({ name: "checkmate-diagnostic", version: "1" });
try {
  await client.connect(
    new StdioClientTransport({
      command: process.execPath,
      args: [fileURLToPath(new URL("./cli.js", import.meta.url))],
    }),
  );
  const catalog = await client.listTools();
  const result = await client.callTool({ name: "get_session", arguments: {} });
  console.log(
    JSON.stringify(
      {
        tools: catalog.tools.map((t) => t.name),
        session: result.structuredContent,
      },
      null,
      2,
    ),
  );
  if (result.isError) process.exitCode = 1;
} catch {
  console.error(
    "Checkmate diagnostic failed. Build the adapter, open the app and enable Companion in Settings.",
  );
  process.exitCode = 1;
} finally {
  await client.close();
}
