import { mkdtemp, writeFile, chmod, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { readDiscovery, BrokerClient } from "../src/broker";
it("fails gracefully when the desktop connection is disabled", async () => {
  const client = new BrokerClient("/nonexistent/checkmate-discovery.json");
  expect(await client.call("get_session", {})).toMatchObject({
    error: { code: "APP_NOT_READY" },
  });
  await client.close();
});
it("requires private, loopback-only discovery and never follows a remote address", async () => {
  const dir = await mkdtemp(join(tmpdir(), "checkmate-"));
  const path = join(dir, "connection.json");
  try {
    await chmod(dir, 0o700);
    await writeFile(
      path,
      JSON.stringify({
        schemaVersion: 1,
        url: "http://127.0.0.1:1234",
        token: "a".repeat(64),
      }),
      { mode: 0o600 },
    );
    expect((await readDiscovery(path)).url).toBe("http://127.0.0.1:1234");
    await chmod(path, 0o644);
    await expect(readDiscovery(path)).rejects.toThrow();
    await chmod(path, 0o600);
    await writeFile(
      path,
      JSON.stringify({
        schemaVersion: 1,
        url: "https://example.com",
        token: "a".repeat(64),
      }),
    );
    await expect(readDiscovery(path)).rejects.toThrow();
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
