#!/usr/bin/env node
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { callHubRpc } from "../src/hub-client.js";

type Agent = "codex" | "claude";

interface Combination {
  parent: Agent;
  child: Agent;
}

const projectRoot = new URL("..", import.meta.url).pathname;
const tempDir = join(projectRoot, "temp");
const hubClientPath = join(projectRoot, "dist", "hub-client.js");
const hubUrl = process.env.HUMANIZE2_JSONRPC_URL ?? "http://127.0.0.1:4772/jsonrpc";

const combinations: Combination[] = [
  { parent: "codex", child: "codex" },
  { parent: "codex", child: "claude" },
  { parent: "claude", child: "codex" },
  { parent: "claude", child: "claude" }
];

async function main(): Promise<void> {
  await mkdir(tempDir, { recursive: true });
  await assertHubAvailable();

  const selected = selectCombinations(process.argv[2] ?? "all");

  for (const combination of selected) {
    await runCombination(combination);
  }
}

function selectCombinations(selection: string): Combination[] {
  if (selection === "all") {
    return combinations;
  }

  const selected = combinations.find((combination) => combinationName(combination) === selection);
  if (selected !== undefined) {
    return [selected];
  }

  const names = ["all", ...combinations.map(combinationName)].join("|");
  throw new Error(`Usage: npm run smoke:nested-market -- <${names}>`);
}

async function runCombination(combination: Combination): Promise<void> {
  const name = combinationName(combination);
  const parentOutputPath = join(tempDir, `nested-market-${name}.md`);
  const childOutputPath = join(tempDir, `nested-market-${name}-child.md`);
  const childRequestPath = join(tempDir, `nested-market-${name}-child-request.json`);
  const childCommand = `${shellQuote(process.execPath)} ${shellQuote(hubClientPath)} run.spawn_child ${shellQuote(`@${childRequestPath}`)}`;

  await writeFile(
    childRequestPath,
    JSON.stringify({
      agent: combination.child,
      prompt: [
        `Create or replace ${childOutputPath} as Markdown.`,
        "Fetch current NVDA and GOOG prices from reliable public market-data sources.",
        "Include the current local date/time with timezone, NVDA and GOOG prices, currencies, source URLs, and retrieval timestamps.",
        "Do not ask follow-up questions."
      ].join(" "),
      cwd: projectRoot,
      timeoutMs: 1_740_000,
      ...agentOptions(combination.child)
    }, null, 2),
    "utf8"
  );

  const prompt = [
    `Create or replace ${parentOutputPath}.`,
    "The file must be Markdown.",
    "Fetch the current BTC and ETH spot prices from the network using reliable public market-data sources such as Coinbase, CoinGecko, Kraken, Yahoo Finance, Nasdaq, or another public endpoint.",
    "Include the current local date and time with timezone.",
    "Include BTC and ETH prices, currencies, source URLs, and retrieval timestamps.",
    `Then submit a logical child run to Humanize2 by running this exact JSON-RPC client command from ${projectRoot}:`,
    childCommand,
    "The command calls the Humanize2 hub over JSON-RPC. Do not create the child by writing a handoff file.",
    "The JSON-RPC client will add the current HUMANIZE2_RUN_ID as the logical parentRunId.",
    "In the parent file, include a concise logical child request section with the command, child agent name, child output path, and command output.",
    "Do not ask follow-up questions."
  ].join(" ");

  const created = await callHubRpc({
    url: hubUrl,
    method: "run.create",
    params: {
      agent: combination.parent,
      prompt,
      cwd: projectRoot,
      timeoutMs: 1_740_000,
      ...agentOptions(combination.parent)
    }
  }) as { runId: string };

  const parent = await waitForRun(created.runId);
  if (parent.status !== "succeeded") {
    throw new Error(`${name} parent smoke failed: ${parent.error ?? JSON.stringify(parent.result)}`);
  }

  const child = await waitForLogicalChild(created.runId, combination.child);
  if (child.status !== "succeeded") {
    throw new Error(`${name} child smoke failed: ${child.error ?? JSON.stringify(child.result)}`);
  }

  await requireOutput(parentOutputPath, ["BTC", "ETH"]);
  await requireOutput(childOutputPath, ["NVDA", "GOOG"]);

  console.log(`${name} wrote ${parentOutputPath} and ${childOutputPath}`);
}

function agentOptions(agent: Agent): Record<string, unknown> {
  if (agent === "codex") {
    return {
      sandbox: "danger-full-access",
      extraArgs: ["--skip-git-repo-check"]
    };
  }

  return {
    permissionMode: "bypassPermissions"
  };
}

async function requireOutput(path: string, markers: string[]): Promise<void> {
  const file = await stat(path);
  if (!file.isFile() || file.size === 0) {
    throw new Error(`Expected a non-empty file at ${path}`);
  }

  const contents = await readFile(path, "utf8");
  const missingMarker = markers.find((marker) => !contents.includes(marker));
  if (missingMarker !== undefined) {
    throw new Error(`Expected ${path} to contain ${missingMarker}`);
  }
}

function combinationName(combination: Combination): string {
  return `${combination.parent}-${combination.child}`;
}

async function assertHubAvailable(): Promise<void> {
  await callHubRpc({
    url: hubUrl,
    method: "system.info",
    params: {}
  });
}

async function waitForRun(runId: string): Promise<RunSnapshot> {
  return callHubRpc({
    url: hubUrl,
    method: "run.wait",
    params: {
      runId,
      timeoutMs: 1_800_000
    }
  }) as Promise<RunSnapshot>;
}

async function waitForLogicalChild(parentRunId: string, agent: Agent): Promise<RunSnapshot> {
  const deadline = Date.now() + 1_800_000;

  while (Date.now() < deadline) {
    const list = await callHubRpc({
      url: hubUrl,
      method: "run.list",
      params: {}
    }) as { runs: RunSnapshot[] };
    const child = list.runs.find((run) => run.parentRunId === parentRunId && run.agent === agent);

    if (child !== undefined) {
      return waitForRun(child.id);
    }

    await new Promise((resolve) => setTimeout(resolve, 1_000));
  }

  throw new Error(`Timed out waiting for logical child of ${parentRunId}`);
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

interface RunSnapshot {
  id: string;
  parentRunId?: string;
  agent: Agent;
  status: "running" | "succeeded" | "failed";
  error?: string;
  result?: unknown;
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.stack ?? error.message : String(error);
  console.error(message);
  process.exit(1);
});
