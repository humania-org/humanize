#!/usr/bin/env node
import { readFile } from "node:fs/promises";

export interface HubRpcOptions {
  url: string;
  method: string;
  params: Record<string, unknown>;
}

export async function callHubRpc(options: HubRpcOptions): Promise<unknown> {
  const response = await fetch(options.url, {
    method: "POST",
    headers: {
      "content-type": "application/json"
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: options.method,
      params: options.params
    })
  });

  const payload = await response.json() as {
    result?: unknown;
    error?: {
      message: string;
    };
  };

  if (payload.error !== undefined) {
    throw new Error(payload.error.message);
  }

  return payload.result;
}

export function applyRunEnvironmentDefaults(
  method: string,
  params: Record<string, unknown>,
  env: NodeJS.ProcessEnv
): Record<string, unknown> {
  if (method === "run.spawn_child" && params.parentRunId === undefined && env.HUMANIZE2_RUN_ID !== undefined) {
    return {
      ...params,
      parentRunId: env.HUMANIZE2_RUN_ID
    };
  }

  if (method === "run.send_message" && params.runId === undefined && env.HUMANIZE2_RUN_ID !== undefined) {
    return {
      ...params,
      runId: env.HUMANIZE2_RUN_ID,
      messageOrigin: messageOriginFromEnvironment(env)
    };
  }

  if (method === "run.send_message" && params.messageOrigin === undefined) {
    const origin = messageOriginFromEnvironment(env);
    if (origin !== undefined) {
      return {
        ...params,
        messageOrigin: origin
      };
    }
  }

  return params;
}

function messageOriginFromEnvironment(env: NodeJS.ProcessEnv): Record<string, unknown> | undefined {
  if (env.HUMANIZE2_RUN_ID === undefined || env.HUMANIZE2_RUN_ID.length === 0) {
    return undefined;
  }
  return {
    kind: "agent",
    sender: env.HUMANIZE2_RUN_SHORT_NAME ?? env.HUMANIZE2_RUN_ID,
    sourceRunId: env.HUMANIZE2_RUN_ID
  };
}

async function parseArguments(rawArguments: string): Promise<Record<string, unknown>> {
  const json = rawArguments.startsWith("@")
    ? await readFile(rawArguments.slice(1), "utf8")
    : rawArguments;
  const parsed = JSON.parse(json) as unknown;

  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("RPC params must be a JSON object");
  }

  return parsed as Record<string, unknown>;
}

async function cliMain(): Promise<void> {
  const [, , method, rawArguments = "{}"] = process.argv;

  if (method === undefined) {
    console.error("Usage: humanize2-rpc <method> [json-params-or-@file]");
    process.exit(2);
  }

  const params = applyRunEnvironmentDefaults(method, await parseArguments(rawArguments), process.env);
  const result = await callHubRpc({
    url: process.env.HUMANIZE2_JSONRPC_URL ?? "http://127.0.0.1:4772/jsonrpc",
    method,
    params
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
