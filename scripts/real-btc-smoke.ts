#!/usr/bin/env node
import { mkdir, stat } from "node:fs/promises";
import { join } from "node:path";

import { callHumanizeTool } from "../src/dev-client.js";

const projectRoot = new URL("..", import.meta.url).pathname;
const tsxCli = join(projectRoot, "node_modules", "tsx", "dist", "cli.mjs");
const tempDir = join(projectRoot, "temp");

const targets = {
  codex: join(tempDir, "btc-price-today-codex.md"),
  claude: join(tempDir, "btc-price-today-claude.md")
} as const;

async function main(): Promise<void> {
  const agent = process.argv[2];

  if (agent !== "codex" && agent !== "claude" && agent !== "all") {
    console.error("Usage: npm run smoke:btc -- <codex|claude|all>");
    process.exit(2);
  }

  await mkdir(tempDir, { recursive: true });

  if (agent === "codex" || agent === "all") {
    await runAgent("codex", targets.codex);
  }

  if (agent === "claude" || agent === "all") {
    await runAgent("claude", targets.claude);
  }
}

async function runAgent(agent: "codex" | "claude", targetPath: string): Promise<void> {
  const prompt = [
    `Create or replace ${targetPath}.`,
    "The file must be Markdown.",
    "Fetch the current BTC spot price from the network using a reliable public source such as Coinbase, CoinGecko, Kraken, or another public market-data endpoint.",
    "Include the current local date and time with timezone.",
    "Include the BTC price, currency, data source URL, and retrieval timestamp.",
    "Keep the file concise. Do not ask follow-up questions."
  ].join(" ");

  const result = await callHumanizeTool({
    command: process.execPath,
    args: [tsxCli, "src/index.ts"],
    cwd: projectRoot,
    env: process.env,
    rpcTimeoutMs: 900_000,
    toolName: "agent_run",
    arguments: {
      agent,
      prompt,
      cwd: projectRoot,
      timeoutMs: 840_000,
      sandbox: agent === "codex" ? "workspace-write" : undefined,
      permissionMode: agent === "claude" ? "bypassPermissions" : undefined,
      extraArgs: agent === "codex" ? ["--skip-git-repo-check"] : undefined
    }
  });

  const textBlock = result.content.find(
    (block): block is { type: "text"; text: string } => block.type === "text"
  );
  const payload = JSON.parse(textBlock?.text ?? "{}") as { success?: boolean; stderr?: string; stdout?: string };

  if (!payload.success) {
    throw new Error(`${agent} smoke failed: ${payload.stderr ?? payload.stdout ?? textBlock?.text ?? "unknown error"}`);
  }

  const file = await stat(targetPath);
  if (!file.isFile() || file.size === 0) {
    throw new Error(`${agent} did not create a non-empty file at ${targetPath}`);
  }

  console.log(`${agent} wrote ${targetPath}`);
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.stack ?? error.message : String(error);
  console.error(message);
  process.exit(1);
});
