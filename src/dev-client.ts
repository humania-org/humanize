#!/usr/bin/env node
import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { readFile } from "node:fs/promises";

export interface ServerProcessOptions {
  command: string;
  args: string[];
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  rpcTimeoutMs?: number;
}

export interface ToolCallOptions extends ServerProcessOptions {
  toolName: string;
  arguments?: Record<string, unknown>;
}

export interface ToolListResult {
  tools: Array<{ name: string; description?: string }>;
}

export interface ToolCallResult {
  content: Array<{ type: "text"; text: string } | Record<string, unknown>>;
  isError?: boolean;
}

export async function parseToolArguments(rawArguments: string): Promise<Record<string, unknown>> {
  const json = rawArguments.startsWith("@")
    ? await readFile(rawArguments.slice(1), "utf8")
    : rawArguments;
  const parsed = JSON.parse(json) as unknown;

  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Tool arguments must be a JSON object");
  }

  return parsed as Record<string, unknown>;
}

interface JsonRpcSuccess {
  jsonrpc: "2.0";
  id: number;
  result: unknown;
}

interface JsonRpcFailure {
  jsonrpc: "2.0";
  id: number;
  error: {
    code: number;
    message: string;
    data?: unknown;
  };
}

type JsonRpcResponse = JsonRpcSuccess | JsonRpcFailure;

export async function listHumanizeTools(options: ServerProcessOptions): Promise<ToolListResult> {
  return withMcpServer(options, async (client) => {
    await client.initialize();
    return client.request<ToolListResult>("tools/list", {});
  });
}

export async function callHumanizeTool(options: ToolCallOptions): Promise<ToolCallResult> {
  return withMcpServer(options, async (client) => {
    await client.initialize();
    return client.request<ToolCallResult>("tools/call", {
      name: options.toolName,
      arguments: options.arguments ?? {}
    });
  });
}

async function withMcpServer<T>(
  options: ServerProcessOptions,
  callback: (client: JsonRpcStdioClient) => Promise<T>
): Promise<T> {
  const child = spawn(options.command, options.args, {
    cwd: options.cwd,
    env: options.env,
    stdio: ["pipe", "pipe", "pipe"]
  });

  const client = new JsonRpcStdioClient(child.stdin, child.stdout, child.stderr, options.rpcTimeoutMs);

  try {
    return await callback(client);
  } finally {
    child.stdin.end();
    child.kill("SIGTERM");
  }
}

class JsonRpcStdioClient {
  private nextId = 1;
  private readonly events = new EventEmitter();
  private stdoutBuffer = "";
  private stderr = "";

  constructor(
    private readonly stdin: NodeJS.WritableStream,
    stdout: NodeJS.ReadableStream,
    stderr: NodeJS.ReadableStream,
    private readonly rpcTimeoutMs = 600_000
  ) {
    stdout.setEncoding("utf8");
    stderr.setEncoding("utf8");

    stdout.on("data", (chunk: string) => {
      this.stdoutBuffer += chunk;
      this.drainStdout();
    });

    stderr.on("data", (chunk: string) => {
      this.stderr += chunk;
    });
  }

  async initialize(): Promise<void> {
    await this.request("initialize", {
      protocolVersion: "2025-11-25",
      capabilities: {},
      clientInfo: {
        name: "humanize2-dev-client",
        version: "0.1.0"
      }
    });
    this.notify("notifications/initialized", {});
  }

  request<T>(method: string, params: unknown): Promise<T> {
    const id = this.nextId++;
    const message = {
      jsonrpc: "2.0",
      id,
      method,
      params
    };

    this.stdin.write(`${JSON.stringify(message)}\n`);

    return new Promise<T>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.events.off(String(id), onResponse);
        reject(new Error(`Timed out waiting for ${method}. Stderr: ${this.stderr}`));
      }, this.rpcTimeoutMs);

      const onResponse = (response: JsonRpcResponse) => {
        clearTimeout(timeout);

        if ("error" in response) {
          reject(new Error(`${response.error.message}: ${JSON.stringify(response.error.data)}`));
          return;
        }

        resolve(response.result as T);
      };

      this.events.once(String(id), onResponse);
    });
  }

  notify(method: string, params: unknown): void {
    this.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
  }

  private drainStdout(): void {
    while (true) {
      const newlineIndex = this.stdoutBuffer.indexOf("\n");
      if (newlineIndex === -1) {
        return;
      }

      const line = this.stdoutBuffer.slice(0, newlineIndex).trim();
      this.stdoutBuffer = this.stdoutBuffer.slice(newlineIndex + 1);

      if (line.length === 0) {
        continue;
      }

      const response = JSON.parse(line) as JsonRpcResponse;
      if ("id" in response) {
        this.events.emit(String(response.id), response);
      }
    }
  }
}

async function cliMain(): Promise<void> {
  const [, , toolName, rawArguments = "{}"] = process.argv;

  if (toolName === undefined) {
    console.error("Usage: humanize2-call <tool-name> [json-arguments]");
    process.exit(2);
  }

  const result = await callHumanizeTool({
    command: process.execPath,
    args: [new URL("../dist/index.js", import.meta.url).pathname],
    cwd: process.cwd(),
    env: process.env,
    rpcTimeoutMs: Number.parseInt(process.env.HUMANIZE2_RPC_TIMEOUT_MS ?? "600000", 10),
    toolName,
    arguments: await parseToolArguments(rawArguments)
  });

  console.log(JSON.stringify(result, null, 2));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  cliMain().catch((error: unknown) => {
    const message = error instanceof Error ? error.stack ?? error.message : String(error);
    console.error(message);
    process.exit(1);
  });
}
