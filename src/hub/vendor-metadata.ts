import { existsSync, readFileSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import type { AgentSessionMetadata } from "./agent-sessions.js";
import type { AgentRunRecord } from "./runs.js";
import {
  addUsageObjectToStats,
  contextInputTokensFromUsageObject,
  emptyTokenStats,
  tokenStatsFromUsageObject,
  type TokenStatsPatch
} from "./token-stats.js";

export function loadVendorSessionMetadataForRuns(
  runs: AgentRunRecord[],
  home = homedir()
): Record<string, AgentSessionMetadata> {
  const codexIds = new Set(
    runs
      .filter((run) => run.agent === "codex")
      .map((run) => run.backendSessionId)
      .filter((id): id is string => id !== undefined && id.length > 0)
  );
  const claudeIds = new Set(
    runs
      .filter((run) => run.agent === "claude")
      .map((run) => run.backendSessionId)
      .filter((id): id is string => id !== undefined && id.length > 0)
  );
  const metadata: Record<string, AgentSessionMetadata> = {};

  for (const id of codexIds) {
    const value = loadCodexSessionMetadata(id, home);
    if (value !== undefined) {
      metadata[id] = value;
    }
  }

  for (const id of claudeIds) {
    const value = loadClaudeSessionMetadata(id, home);
    if (value !== undefined) {
      metadata[id] = value;
    }
  }

  return metadata;
}

function loadCodexSessionMetadata(sessionId: string, home: string): AgentSessionMetadata | undefined {
  const sessionsDir = join(home, ".codex", "sessions");
  if (!existsSync(sessionsDir)) {
    return undefined;
  }

  const path = findFileContainingName(sessionsDir, sessionId);
  if (path === undefined) {
    return undefined;
  }

  const metadata: AgentSessionMetadata = {};
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (line.trim().length === 0) {
      continue;
    }
    let value: unknown;
    try {
      value = JSON.parse(line) as unknown;
    } catch {
      continue;
    }
    const object = asRecord(value);
    if (object?.type === "turn_context") {
      const payload = asRecord(object.payload);
      const model = stringValue(payload?.model);
      const effort = stringValue(payload?.effort)
        ?? stringValue(asRecord(asRecord(payload?.collaboration_mode)?.settings)?.reasoning_effort);
      metadata.model = model ?? metadata.model;
      metadata.reasoningEffort = effort ?? metadata.reasoningEffort;
    }
    if (object?.type === "event_msg") {
      const payload = asRecord(object.payload);
      const info = asRecord(payload?.info);
      metadata.contextWindowTokens = numberValue(info?.model_context_window)
        ?? numberValue(payload?.model_context_window)
        ?? metadata.contextWindowTokens;
      if (payload?.type === "token_count" && info !== undefined) {
        assignTokenStats(metadata, tokenStatsFromUsageObject(info.total_token_usage));
        const latestUsage = info.last_token_usage;
        metadata.contextUsedTokens = contextInputTokensFromUsageObject(latestUsage) ?? metadata.contextUsedTokens;
      }
    }
  }

  return Object.keys(metadata).length === 0 ? undefined : metadata;
}

function loadClaudeSessionMetadata(sessionId: string, home: string): AgentSessionMetadata | undefined {
  const projectsDir = join(home, ".claude", "projects");
  if (!existsSync(projectsDir)) {
    return undefined;
  }

  const path = findFileContainingName(projectsDir, sessionId);
  if (path === undefined) {
    return undefined;
  }

  const metadata: AgentSessionMetadata = {};
  const totals = emptyTokenStats();
  const seenUsageRecords = new Set<string>();
  let hasUsage = false;

  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (line.trim().length === 0) {
      continue;
    }
    let value: unknown;
    try {
      value = JSON.parse(line) as unknown;
    } catch {
      continue;
    }

    const object = asRecord(value);
    const message = asRecord(object?.message);
    if (message === undefined) {
      continue;
    }
    const model = stringValue(message?.model);
    if (model !== undefined && model !== "<synthetic>") {
      metadata.model = model;
    }

    const usage = asRecord(message?.usage);
    if (usage === undefined) {
      continue;
    }

    const key = claudeUsageKey(object, message);
    if (key !== undefined) {
      if (seenUsageRecords.has(key)) {
        continue;
      }
      seenUsageRecords.add(key);
    }

    addUsageObjectToStats(usage, totals);
    hasUsage = true;
    metadata.contextUsedTokens = contextInputTokensFromUsageObject(usage) ?? metadata.contextUsedTokens;
  }

  if (hasUsage) {
    assignTokenStats(metadata, totals);
  }

  return Object.keys(metadata).length === 0 ? undefined : metadata;
}

function assignTokenStats(metadata: AgentSessionMetadata, patch: TokenStatsPatch | undefined): void {
  if (patch === undefined) {
    return;
  }
  metadata.inputTokens = patch.inputTokens ?? metadata.inputTokens;
  metadata.outputTokens = patch.outputTokens ?? metadata.outputTokens;
  metadata.cacheReadInputTokens = patch.cacheReadInputTokens ?? metadata.cacheReadInputTokens;
  metadata.cacheCreationInputTokens = patch.cacheCreationInputTokens ?? metadata.cacheCreationInputTokens;
  metadata.reasoningOutputTokens = patch.reasoningOutputTokens ?? metadata.reasoningOutputTokens;
}

function findFileContainingName(root: string, needle: string): string | undefined {
  const stack = [root];
  while (stack.length > 0) {
    const directory = stack.pop() ?? root;
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) {
        stack.push(path);
      } else if (entry.isFile() && entry.name.includes(needle) && entry.name.endsWith(".jsonl")) {
        return path;
      }
    }
  }

  return undefined;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }

  return value as Record<string, unknown>;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function claudeUsageKey(object: Record<string, unknown> | undefined, message: Record<string, unknown>): string | undefined {
  const messageId = stringValue(message.id);
  const requestId = stringValue(object?.requestId);
  if (messageId !== undefined && requestId !== undefined) {
    return `${messageId}:${requestId}`;
  }

  return stringValue(object?.uuid) ?? stringValue(object?.timestamp);
}
