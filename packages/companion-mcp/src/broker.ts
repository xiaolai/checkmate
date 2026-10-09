import { readFile, lstat } from "node:fs/promises";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { randomUUID } from "node:crypto";
export interface Backend {
  call(method: string, args: unknown, signal?: AbortSignal): Promise<unknown>;
  close?(): Promise<void>;
}
export function discoveryPath() {
  const base =
    process.platform === "darwin"
      ? join(homedir(), "Library/Application Support")
      : process.platform === "win32"
        ? process.env.LOCALAPPDATA || join(homedir(), "AppData/Local")
        : process.env.XDG_DATA_HOME || join(homedir(), ".local/share");
  return join(base, "ai.xiaolai.checkmate", "companion", "connection.json");
}
export async function readDiscovery(path: string) {
  const [file, dir] = await Promise.all([lstat(path), lstat(dirname(path))]);
  if (
    !file.isFile() ||
    file.isSymbolicLink() ||
    !dir.isDirectory() ||
    dir.isSymbolicLink() ||
    file.size > 4096
  )
    throw Error("Invalid discovery file.");
  if (
    process.platform !== "win32" &&
    ((file.mode & 0o077) !== 0 ||
      (dir.mode & 0o077) !== 0 ||
      file.uid !== process.getuid?.() ||
      dir.uid !== process.getuid?.())
  )
    throw Error("Discovery permissions are not private.");
  const value = JSON.parse(await readFile(path, "utf8"));
  if (value.schemaVersion !== 1) throw Error("INCOMPATIBLE_SCHEMA");
  if (
    typeof value.token !== "string" ||
    !/^[a-f0-9]{64}$/.test(value.token) ||
    typeof value.url !== "string" ||
    !/^http:\/\/127\.0\.0\.1:\d+$/.test(value.url)
  )
    throw Error("Invalid discovery contents.");
  const url = new URL(value.url);
  if (Number(url.port) < 1 || Number(url.port) > 65535)
    throw Error("Invalid discovery endpoint.");
  return { url: value.url as string, token: value.token as string };
}
export class BrokerClient implements Backend {
  private client = randomUUID();
  private discovery: Awaited<ReturnType<typeof readDiscovery>> | null = null;
  private heartbeat: ReturnType<typeof setInterval> | undefined;
  private closed = false;
  private closing: Promise<void> | undefined;
  constructor(private path = discoveryPath()) {}
  private headers() {
    return {
      "content-type": "application/json",
      authorization: `Bearer ${this.discovery!.token}`,
      "x-checkmate-client": this.client,
    };
  }
  private async send(path: string, body: unknown, signal?: AbortSignal) {
    const d = this.discovery!;
    const response = await fetch(d.url + path, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify(body),
      signal: signal
        ? AbortSignal.any([signal, AbortSignal.timeout(26000)])
        : AbortSignal.timeout(3000),
      redirect: "error",
    });
    const text = await response.text();
    if (text.length > 131072) throw Error("Oversized response.");
    return JSON.parse(text);
  }
  async call(method: string, args: unknown, signal?: AbortSignal) {
    if (this.closed)
      return {
        error: {
          code: "DISCONNECTED",
          message: "Start a new companion connection.",
        },
      };
    try {
      this.discovery = await readDiscovery(this.path);
    } catch (error) {
      return {
        error: {
          code:
            error instanceof Error && error.message === "INCOMPATIBLE_SCHEMA"
              ? "INCOMPATIBLE_SCHEMA"
              : "APP_NOT_READY",
          message:
            "Open Checkmate and enable Companion in Settings. The app and server must use the same protocol version.",
        },
      };
    }
    const id = randomUUID(),
      controller = new AbortController();
    const abort = () => {
      controller.abort();
      void this.send("/cancel", { id }).catch(() => {});
    };
    signal?.addEventListener("abort", abort, { once: true });
    if (signal?.aborted) abort();
    try {
      const result = await this.send(
        "/rpc",
        { id, method, args },
        AbortSignal.any([controller.signal, AbortSignal.timeout(25000)]),
      );
      if (!this.heartbeat && !result.error) {
        this.heartbeat = setInterval(
          () =>
            void this.send("/heartbeat", {})
              .then((value) => {
                if (value.error) {
                  clearInterval(this.heartbeat);
                  this.heartbeat = undefined;
                }
              })
              .catch(() => {
                clearInterval(this.heartbeat);
                this.heartbeat = undefined;
              }),
          10000,
        );
        this.heartbeat.unref();
      }
      return result;
    } catch {
      return {
        error: {
          code: signal?.aborted ? "CANCELLED" : "CONNECTION_LOST",
          message:
            "Read the current session before retrying. A timed-out move may already have completed; reuse its requestId.",
        },
      };
    } finally {
      signal?.removeEventListener("abort", abort);
    }
  }
  close(): Promise<void> {
    if (this.closing) return this.closing;
    this.closed = true;
    clearInterval(this.heartbeat);
    this.closing = this.discovery
      ? this.send("/disconnect", {})
          .then(() => {})
          .catch(() => {})
      : Promise.resolve();
    return this.closing;
  }
}
