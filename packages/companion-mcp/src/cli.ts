#!/usr/bin/env node
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { BrokerClient } from "./broker.js";
import { createServer } from "./server.js";
const backend = new BrokerClient();
const server = createServer(backend);
for (const event of ["SIGINT", "SIGTERM"] as const)
  process.on(event, () => {
    void backend.close().finally(() => process.exit(0));
  });
process.stdin.on("end", () => {
  void backend.close();
});
await server.connect(new StdioServerTransport());
