import type { AgentId } from "../agents/types.js";
import type { AgentModelDefaultsByAgent, AgentModelDefaults } from "../config.js";
import type { RunProjectMetadata } from "./run-metadata.js";
import type { AgentMessageOrigin, AgentRunOutputEvent, AgentRunRecord, AgentRunStatus } from "./runs.js";
import {
  addUsageObjectToStats,
  applyTokenStatsPatch,
  contextInputTokensFromUsageObject,
  emptyTokenStats,
  recomputeTotalTokens,
  type TokenStatsFields,
  type TokenStatsPatch
} from "./token-stats.js";

export interface AgentSessionRecord {
  id: string;
  title: string;
  sessionId: string;
  vendorSessionId?: string;
  agent: AgentId;
  model?: string;
  reasoningEffort?: string;
  modelLabel: string;
  cwd?: string;
  project: RunProjectMetadata;
  status: AgentRunStatus;
  parentSessionId?: string;
  startedAt: string;
  finishedAt?: string;
  durationMs: number;
  timeoutMs: number;
  currentRunId: string;
  previousRunId?: string;
  attempts: AgentSessionAttempt[];
  stats: AgentSessionStats;
  inputHistory: AgentSessionInputEntry[];
  outputEvents: AgentRunOutputEvent[];
  resultStdout?: string;
  resultStderr?: string;
}

export interface AgentSessionAttempt {
  runId: string;
  shortName: string;
  status: AgentRunStatus;
  startedAt: string;
  finishedAt?: string;
  durationMs: number;
  timeoutMs: number;
}

export interface AgentSessionStats extends TokenStatsFields {
  contextUsedTokens?: number;
  contextWindowTokens?: number;
  contextUsagePercent?: number;
}

export interface AgentSessionMetadata extends TokenStatsPatch {
  model?: string;
  reasoningEffort?: string;
  contextUsedTokens?: number;
  contextWindowTokens?: number;
}

export interface BuildAgentSessionsOptions {
  now?: string;
  agentDefaults?: AgentModelDefaultsByAgent;
  metadataByVendorSessionId?: Record<string, AgentSessionMetadata>;
}

export interface AgentSessionInputEntry {
  runId: string;
  timestamp: string;
  kind: "prompt" | "intervention";
  text: string;
  origin?: AgentMessageOrigin;
}

export function buildAgentSessions(
  runs: AgentRunRecord[],
  options: string | BuildAgentSessionsOptions = {}
): AgentSessionRecord[] {
  const resolvedOptions: BuildAgentSessionsOptions = typeof options === "string" ? { now: options } : options;
  const now = resolvedOptions.now ?? new Date().toISOString();
  const runById = new Map(runs.map((run) => [run.id, run]));
  const rootCache = new Map<string, string>();
  const rootForRun = (run: AgentRunRecord): string => findRootRunId(run, runById, rootCache);
  const groups = new Map<string, AgentRunRecord[]>();

  for (const run of runs) {
    const rootId = rootForRun(run);
    const group = groups.get(rootId) ?? [];
    group.push(run);
    groups.set(rootId, group);
  }
  const rootByRunId = new Map(runs.map((run) => [run.id, rootForRun(run)]));

  return [...groups.entries()]
    .map(([rootId, group]) => buildSession(rootId, group, rootByRunId, now, resolvedOptions))
    .sort((left, right) => left.startedAt.localeCompare(right.startedAt));
}

function buildSession(
  rootId: string,
  group: AgentRunRecord[],
  rootByRunId: Map<string, string>,
  now: string,
  options: BuildAgentSessionsOptions
): AgentSessionRecord {
  const attempts = [...group].sort(compareRuns);
  const latest = attempts[attempts.length - 1];
  const previous = attempts.length > 1 ? attempts[attempts.length - 2] : undefined;
  const startedAt = earliest(attempts.map((run) => run.startedAt ?? run.createdAt));
  const finishedAt = latest.status === "running" ? undefined : latest.finishedAt ?? now;
  const endTime = Date.parse(finishedAt ?? now);
  const durationMs = Math.max(0, endTime - Date.parse(startedAt));
  const vendorSessionId = latest.backendSessionId ?? attempts.find((run) => run.backendSessionId !== undefined)?.backendSessionId;
  const outputEvents = attempts.flatMap((run) => run.outputEvents.map((event) => ({ ...event })));
  const metadata = vendorSessionId === undefined ? undefined : options.metadataByVendorSessionId?.[vendorSessionId];
  const modelMetadata = resolveModelMetadata(latest.agent, attempts, outputEvents, metadata, options.agentDefaults?.[latest.agent]);
  const stats = collectStats(outputEvents);
  applyTokenStatsPatch(stats, metadata);
  const contextUsedTokens = metadata?.contextUsedTokens ?? stats.contextUsedTokens;
  const contextWindowTokens = metadata?.contextWindowTokens ?? contextWindowTokensForModel(modelMetadata.model);
  if (contextUsedTokens !== undefined) {
    stats.contextUsedTokens = contextUsedTokens;
  }
  if (contextWindowTokens !== undefined) {
    stats.contextWindowTokens = contextWindowTokens;
  }
  if (stats.contextUsedTokens !== undefined && stats.contextWindowTokens !== undefined) {
    stats.contextUsagePercent = (stats.contextUsedTokens / stats.contextWindowTokens) * 100;
  }
  const parentRun = attempts.find((run) => run.parentRunId !== undefined);
  const parentSessionId = parentRun?.parentRunId === undefined ? undefined : rootByRunId.get(parentRun.parentRunId) ?? parentRun.parentRunId;

  return {
    id: rootId,
    title: deriveSessionTitle(attempts),
    sessionId: vendorSessionId ?? rootId,
    vendorSessionId,
    agent: latest.agent,
    model: modelMetadata.model,
    reasoningEffort: modelMetadata.reasoningEffort,
    modelLabel: modelMetadata.modelLabel,
    cwd: latest.cwd ?? attempts.find((run) => run.cwd !== undefined)?.cwd,
    project: latest.project,
    status: latest.status,
    parentSessionId,
    startedAt,
    finishedAt,
    durationMs,
    timeoutMs: latest.timeoutMs,
    currentRunId: latest.id,
    previousRunId: previous?.id,
    attempts: attempts.map((run) => ({
      runId: run.id,
      shortName: run.shortName,
      status: run.status,
      startedAt: run.startedAt ?? run.createdAt,
      finishedAt: run.finishedAt,
      durationMs: run.durationMs ?? Math.max(0, Date.parse(run.finishedAt ?? now) - Date.parse(run.startedAt ?? run.createdAt)),
      timeoutMs: run.timeoutMs
    })),
    stats,
    inputHistory: attempts.flatMap((run) => inputEntriesForRun(run)),
    outputEvents,
    resultStdout: joinResults(attempts, "stdout"),
    resultStderr: joinResults(attempts, "stderr")
  };
}

function findRootRunId(run: AgentRunRecord, runById: Map<string, AgentRunRecord>, cache: Map<string, string>): string {
  const cached = cache.get(run.id);
  if (cached !== undefined) {
    return cached;
  }

  const visited = new Set<string>();
  let current = run;
  while (current.continuedFromRunId !== undefined && runById.has(current.continuedFromRunId)) {
    if (visited.has(current.id)) {
      break;
    }
    visited.add(current.id);
    current = runById.get(current.continuedFromRunId) ?? current;
  }

  cache.set(run.id, current.id);
  return current.id;
}

function compareRuns(left: AgentRunRecord, right: AgentRunRecord): number {
  const byStart = (left.startedAt ?? left.createdAt).localeCompare(right.startedAt ?? right.createdAt);
  return byStart === 0 ? left.createdAt.localeCompare(right.createdAt) : byStart;
}

function earliest(values: string[]): string {
  return [...values].sort()[0] ?? new Date(0).toISOString();
}

function inputEntriesForRun(run: AgentRunRecord): AgentSessionInputEntry[] {
  const entries: AgentSessionInputEntry[] = [];
  if (run.interventionMessage !== undefined && run.interventionMessage.length > 0) {
    entries.push({
      runId: run.id,
      timestamp: run.startedAt ?? run.createdAt,
      kind: "intervention",
      text: run.interventionMessage,
      origin: run.messageOrigin === undefined ? undefined : { ...run.messageOrigin }
    });
    if (run.prompt === run.interventionMessage) {
      return entries;
    }
  }
  entries.push({
    runId: run.id,
    timestamp: run.startedAt ?? run.createdAt,
    kind: "prompt",
    text: run.prompt
  });

  return entries;
}

function deriveSessionTitle(attempts: AgentRunRecord[]): string {
  for (const run of attempts) {
    const workerMatch = /^worker-\d+/.exec(run.shortName);
    if (workerMatch !== null) {
      return workerMatch[0];
    }
  }

  if (attempts.some((run) => run.shortName.startsWith("captain"))) {
    return "captain";
  }

  return attempts[0]?.shortName.replace(/-intervention$/, "") ?? "agent session";
}

function collectStats(events: AgentRunOutputEvent[]): AgentSessionStats {
  const accumulator: UsageAccumulator = {
    aggregateStats: emptyTokenStats(),
    messageStats: emptyTokenStats(),
    messageUsageKeys: new Set()
  };

  for (const event of events) {
    for (const line of event.text.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed.startsWith("{")) {
        continue;
      }
      try {
        collectUsageFromValue(JSON.parse(trimmed) as unknown, accumulator);
      } catch {
        continue;
      }
    }
  }
  const stats: AgentSessionStats = accumulator.hasAggregateStats
    ? { ...accumulator.aggregateStats }
    : { ...accumulator.messageStats };
  if (accumulator.contextUsedTokens !== undefined) {
    stats.contextUsedTokens = accumulator.contextUsedTokens;
  }
  return stats;
}

interface UsageAccumulator {
  aggregateStats: TokenStatsFields;
  messageStats: TokenStatsFields;
  hasAggregateStats?: boolean;
  contextUsedTokens?: number;
  messageUsageKeys: Set<string>;
}

function collectUsageFromValue(value: unknown, accumulator: UsageAccumulator): void {
  if (value === null || typeof value !== "object") {
    return;
  }

  const object = value as Record<string, unknown>;
  if (object.type === "turn.completed") {
    collectAggregateUsageObject(object.usage, accumulator);
    return;
  }

  if (object.type === "result") {
    collectResultUsageObject(object, accumulator);
    return;
  }

  if (object.type === "assistant") {
    const message = asRecord(object.message);
    if (message !== undefined) {
      collectMessageUsageObject(message.usage, accumulator, usageDedupKey(message));
    }
    collectMessageUsageObject(object.usage, accumulator, usageDedupKey(object));
  } else if (object.type === "message") {
    collectMessageUsageObject(object.usage, accumulator, usageDedupKey(object));
  } else {
    collectMessageUsageObject(object.usage, accumulator, usageDedupKey(object));
    collectMessageUsageObject(object.token_usage, accumulator, usageDedupKey(object));
  }

  for (const child of Object.values(object)) {
    if (child !== object.usage && child !== object.token_usage && child !== object.message) {
      collectUsageFromValue(child, accumulator);
    }
  }
}

function collectResultUsageObject(object: Record<string, unknown>, accumulator: UsageAccumulator): void {
  const modelUsage = asRecord(object.modelUsage);
  if (modelUsage !== undefined) {
    for (const value of Object.values(modelUsage)) {
      collectAggregateUsageObject(value, accumulator);
    }
    return;
  }

  collectAggregateUsageObject(object.usage, accumulator);
}

function collectAggregateUsageObject(value: unknown, accumulator: UsageAccumulator): void {
  const before = accumulator.aggregateStats.totalTokens;
  addUsageObjectToStats(value, accumulator.aggregateStats);
  if (accumulator.aggregateStats.totalTokens !== before) {
    accumulator.hasAggregateStats = true;
  }
}

function collectMessageUsageObject(value: unknown, accumulator: UsageAccumulator, key: string | undefined): void {
  if (value === undefined) {
    return;
  }
  const scopedKey = key === undefined ? undefined : `${key}:${JSON.stringify(value)}`;
  if (scopedKey !== undefined) {
    if (accumulator.messageUsageKeys.has(scopedKey)) {
      return;
    }
    accumulator.messageUsageKeys.add(scopedKey);
  }

  const before = accumulator.messageStats.totalTokens;
  addUsageObjectToStats(value, accumulator.messageStats);
  if (accumulator.messageStats.totalTokens === before) {
    return;
  }
  accumulator.contextUsedTokens = contextInputTokensFromUsageObject(value) ?? accumulator.contextUsedTokens;
  recomputeTotalTokens(accumulator.messageStats);
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }

  return value as Record<string, unknown>;
}

function usageDedupKey(object: Record<string, unknown>): string | undefined {
  const id = object.id;
  if (typeof id === "string" && id.length > 0) {
    return id;
  }
  const uuid = object.uuid;
  return typeof uuid === "string" && uuid.length > 0 ? uuid : undefined;
}

function joinResults(attempts: AgentRunRecord[], key: "stdout" | "stderr"): string | undefined {
  const joined = attempts
    .map((run) => run.result?.[key])
    .filter((text): text is string => text !== undefined && text.length > 0)
    .join("\n");

  return joined.length === 0 ? undefined : joined;
}

interface ResolvedModelMetadata {
  model?: string;
  reasoningEffort?: string;
  modelLabel: string;
}

function resolveModelMetadata(
  agent: AgentId,
  attempts: AgentRunRecord[],
  outputEvents: AgentRunOutputEvent[],
  metadata: AgentSessionMetadata | undefined,
  defaults: AgentModelDefaults | undefined
): ResolvedModelMetadata {
  const model = firstString(
    modelFromOutputEvents(outputEvents),
    metadata?.model,
    firstString(...[...attempts].reverse().map((run) => nonDefaultString(run.model))),
    defaults?.model
  );
  const reasoningEffort = firstString(
    firstString(...[...attempts].reverse().map((run) => run.reasoningEffort)),
    reasoningEffortFromResultArgs(attempts),
    reasoningEffortFromOutputEvents(outputEvents),
    metadata?.reasoningEffort,
    defaults?.reasoningEffort
  );

  return {
    model,
    reasoningEffort,
    modelLabel: formatModelLabel(agent, model, reasoningEffort)
  };
}

function modelFromOutputEvents(events: AgentRunOutputEvent[]): string | undefined {
  return firstExtractedString(events, ["model", "model_id", "display_name"]);
}

function reasoningEffortFromOutputEvents(events: AgentRunOutputEvent[]): string | undefined {
  return firstExtractedString(events, ["reasoning_effort", "reasoningEffort", "effortLevel", "effort"]);
}

function firstExtractedString(events: AgentRunOutputEvent[], keys: string[]): string | undefined {
  for (const event of events) {
    for (const line of event.text.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed.startsWith("{")) {
        continue;
      }
      try {
        const value = extractStringByKey(JSON.parse(trimmed) as unknown, keys);
        if (value !== undefined) {
          return value;
        }
      } catch {
        continue;
      }
    }
  }

  return undefined;
}

function extractStringByKey(value: unknown, keys: string[]): string | undefined {
  if (value === null || typeof value !== "object") {
    return undefined;
  }

  const object = value as Record<string, unknown>;
  for (const key of keys) {
    const candidate = object[key];
    if (typeof candidate === "string" && candidate.length > 0) {
      return candidate;
    }
  }
  for (const child of Object.values(object)) {
    const found = extractStringByKey(child, keys);
    if (found !== undefined) {
      return found;
    }
  }

  return undefined;
}

function reasoningEffortFromResultArgs(attempts: AgentRunRecord[]): string | undefined {
  for (const run of [...attempts].reverse()) {
    const args = run.result?.args;
    if (args === undefined) {
      continue;
    }
    for (let index = 0; index < args.length; index += 1) {
      if (args[index] === "--effort" && args[index + 1] !== undefined) {
        return args[index + 1];
      }
      if ((args[index] === "-c" || args[index] === "--config") && args[index + 1] !== undefined) {
        const match = /^model_reasoning_effort\s*=\s*"?([^"]+)"?$/.exec(args[index + 1]);
        if (match !== null) {
          return match[1];
        }
      }
    }
  }

  return undefined;
}

function formatModelLabel(agent: AgentId, model: string | undefined, reasoningEffort: string | undefined): string {
  const displayModel = model === undefined ? agent : normalizeModelName(model);
  return reasoningEffort === undefined ? displayModel : `${displayModel} ${reasoningEffort}`;
}

function normalizeModelName(model: string): string {
  const trimmed = model.trim();
  const oneMillionSuffix = /\[1m\]$/i.test(trimmed);
  const withoutSuffix = trimmed.replace(/\[1m\]$/i, "");
  const claudeMatch = /(?:^|[/.])claude-(opus|sonnet|haiku)-(\d+)-(\d+)/i.exec(withoutSuffix);
  if (claudeMatch !== null) {
    return `${claudeMatch[1].toLowerCase()}-${claudeMatch[2]}.${claudeMatch[3]}${oneMillionSuffix ? "[1m]" : ""}`;
  }

  return trimmed;
}

function contextWindowTokensForModel(model: string | undefined): number | undefined {
  const normalized = model?.toLowerCase() ?? "";
  if (normalized.length === 0) {
    return undefined;
  }
  if (/\[1m\]$/.test(normalized)) {
    return 1_000_000;
  }
  if (/claude-(opus-4-[67]|sonnet-4-6)\b/.test(normalized)) {
    return 1_000_000;
  }
  if (/claude|opus|sonnet|haiku/.test(normalized)) {
    return 200_000;
  }
  if (/^gpt-5\.5\b/.test(normalized)) {
    return 258_400;
  }
  if (/^gpt-5\b/.test(normalized)) {
    return 400_000;
  }
  if (/^gpt-4\.1\b|^o[34]\b/.test(normalized)) {
    return 1_000_000;
  }

  return undefined;
}

function nonDefaultString(value: string | undefined): string | undefined {
  if (value === undefined || value.trim().length === 0 || value === "default") {
    return undefined;
  }

  return value;
}

function firstString(...values: Array<string | undefined>): string | undefined {
  return values.find((value): value is string => value !== undefined && value.length > 0);
}
