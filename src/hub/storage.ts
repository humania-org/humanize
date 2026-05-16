import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync, appendFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import { DEFAULT_RUN_TIMEOUT_MS } from "../config.js";
import { collectProjectMetadata, deriveShortName } from "./run-metadata.js";
import type { AgentRunOutputEvent, AgentRunRecord } from "./runs.js";

export const RUN_SCHEMA_VERSION = "humanize2.run.v1";
export const SESSION_SCHEMA_VERSION = "humanize2.session.v1";

export interface RunSessionRecord {
  schemaVersion: typeof SESSION_SCHEMA_VERSION;
  sessionId: string;
  startedAt: string;
  processId: number;
  stateDir: string;
}

export interface FileRunStoreOptions {
  stateDir: string;
  sessionId: string;
  now?: () => string;
}

type RunLogEntry =
  | { type: "run.created"; record: AgentRunRecord }
  | { type: "run.output"; runId: string; event: AgentRunOutputEvent }
  | { type: "run.finished"; record: AgentRunRecord };

export function resolveStateDir(env: NodeJS.ProcessEnv = process.env, home = homedir()): string {
  if (env.HUMANIZE2_STATE_DIR !== undefined && env.HUMANIZE2_STATE_DIR.length > 0) {
    return env.HUMANIZE2_STATE_DIR;
  }

  if (env.HUMANIZE2_CACHE_DIR !== undefined && env.HUMANIZE2_CACHE_DIR.length > 0) {
    return env.HUMANIZE2_CACHE_DIR;
  }

  return join(home, ".h2", "cache");
}

export class FileRunStore {
  readonly session: RunSessionRecord;
  private readonly sessionDir: string;

  private constructor(
    readonly stateDir: string,
    readonly sessionId: string,
    private readonly now: () => string
  ) {
    this.sessionDir = join(stateDir, "sessions", sessionId);
    this.session = {
      schemaVersion: SESSION_SCHEMA_VERSION,
      sessionId,
      startedAt: now(),
      processId: process.pid,
      stateDir
    };
  }

  static async create(options: FileRunStoreOptions): Promise<FileRunStore> {
    const store = new FileRunStore(options.stateDir, options.sessionId, options.now ?? (() => new Date().toISOString()));
    mkdirSync(join(store.sessionDir, "runs"), { recursive: true });
    writeFileSync(join(store.sessionDir, "session.json"), JSON.stringify(store.session, null, 2), "utf8");
    return store;
  }

  listSessions(): RunSessionRecord[] {
    const sessionsDir = join(this.stateDir, "sessions");
    if (!existsSync(sessionsDir)) {
      return [];
    }

    return readdirSync(sessionsDir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .flatMap((entry) => {
        const sessionPath = join(sessionsDir, entry.name, "session.json");
        if (!existsSync(sessionPath)) {
          return [];
        }

        return [JSON.parse(readFileSync(sessionPath, "utf8")) as RunSessionRecord];
      })
      .sort((left, right) => left.startedAt.localeCompare(right.startedAt));
  }

  async loadRuns(): Promise<AgentRunRecord[]> {
    const sessionsDir = join(this.stateDir, "sessions");
    if (!existsSync(sessionsDir)) {
      return [];
    }

    const records = readdirSync(sessionsDir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .flatMap((entry) => this.loadSessionRuns(entry.name))
      .map((record) => record.status === "running"
        ? {
            ...record,
            status: "interrupted" as const,
            finishedAt: record.finishedAt ?? this.now(),
            error: record.error ?? "Hub session ended before this run finished"
          }
        : record);

    return records.sort((left, right) => left.createdAt.localeCompare(right.createdAt));
  }

  recordRunCreated(record: AgentRunRecord): void {
    this.appendRunEntry(record.id, { type: "run.created", record });
  }

  recordRunOutput(runId: string, event: AgentRunOutputEvent): void {
    this.appendRunEntry(runId, { type: "run.output", runId, event });
  }

  recordRunFinished(record: AgentRunRecord): void {
    this.appendRunEntry(record.id, { type: "run.finished", record });
  }

  private loadSessionRuns(sessionId: string): AgentRunRecord[] {
    const runsDir = join(this.stateDir, "sessions", sessionId, "runs");
    if (!existsSync(runsDir)) {
      return [];
    }

    return readdirSync(runsDir, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith(".jsonl"))
      .flatMap((entry) => this.loadRunLog(join(runsDir, entry.name)));
  }

  private loadRunLog(path: string): AgentRunRecord[] {
    const entries = readFileSync(path, "utf8")
      .split("\n")
      .filter((line) => line.trim().length > 0)
      .map((line) => JSON.parse(line) as RunLogEntry);

    let record: AgentRunRecord | undefined;
    for (const entry of entries) {
      switch (entry.type) {
        case "run.created":
          record = { ...entry.record, outputEvents: [...entry.record.outputEvents] };
          break;
        case "run.output":
          if (record !== undefined) {
            record.outputEvents.push({ ...entry.event });
          }
          break;
        case "run.finished":
          record = {
            ...entry.record,
            outputEvents: record?.outputEvents ?? [...entry.record.outputEvents]
          };
          break;
      }
    }

    return record === undefined ? [] : [normalizeLoadedRun(record)];
  }

  private appendRunEntry(runId: string, entry: RunLogEntry): void {
    const runPath = join(this.sessionDir, "runs", `${runId}.jsonl`);
    mkdirSync(join(this.sessionDir, "runs"), { recursive: true });
    appendFileSync(runPath, `${JSON.stringify(entry)}\n`, "utf8");
  }
}

function normalizeLoadedRun(record: AgentRunRecord): AgentRunRecord {
  return {
    ...record,
    shortName: record.shortName ?? deriveShortName(record.prompt),
    timeoutMs: record.timeoutMs ?? DEFAULT_RUN_TIMEOUT_MS,
    project: record.project ?? collectProjectMetadata(record.cwd)
  };
}
