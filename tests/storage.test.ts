import { mkdtemp, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { afterEach, describe, expect, it } from "vitest";

import type { AgentBackend, AgentId, AgentRequest, AgentResult, AgentStatus } from "../src/agents/types.js";
import { AgentRunCoordinator } from "../src/hub/runs.js";
import { FileRunStore, RUN_SCHEMA_VERSION, resolveStateDir } from "../src/hub/storage.js";
import { HumanizeService } from "../src/service.js";

const tempDirs: string[] = [];

afterEach(async () => {
  await Promise.all(tempDirs.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

async function tempDirectory(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "humanize2-store-"));
  tempDirs.push(directory);
  return directory;
}

function fakeBackend(id: AgentId): AgentBackend {
  return {
    id,
    displayName: `${id} backend`,
    async status(): Promise<AgentStatus> {
      return {
        agent: id,
        displayName: `${id} backend`,
        available: true
      };
    },
    async run(request: AgentRequest): Promise<AgentResult> {
      request.onOutput?.({ stream: "stdout", text: "stored stdout" });
      request.onOutput?.({ stream: "stderr", text: "stored stderr" });
      return {
        agent: id,
        success: true,
        exitCode: 0,
        signal: null,
        stdout: "stored stdout",
        stderr: "stored stderr",
        durationMs: 1,
        timedOut: false,
        command: id,
        args: [request.prompt],
        cwd: request.cwd
      };
    }
  };
}

function service(): HumanizeService {
  return new HumanizeService([fakeBackend("codex"), fakeBackend("claude")]);
}

describe("persistent run storage", () => {
  it("resolves the per-user state directory from environment and home", () => {
    expect(resolveStateDir({ HUMANIZE2_STATE_DIR: "/tmp/h2-state" }, "/home/user")).toBe("/tmp/h2-state");
    expect(resolveStateDir({ HUMANIZE2_CACHE_DIR: "/tmp/h2-cache" }, "/home/user")).toBe("/tmp/h2-cache");
    expect(resolveStateDir({}, "/home/user")).toBe("/home/user/.h2/cache");
  });

  it("writes versioned session and run logs and restores them", async () => {
    const stateDir = await tempDirectory();
    const store = await FileRunStore.create({
      stateDir,
      sessionId: "session-a",
      now: () => "2026-05-12T21:00:00.000Z"
    });
    const runs = new AgentRunCoordinator(service(), {
      jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc",
      idFactory: () => "run-a",
      store
    });

    const created = runs.createRun({ agent: "codex", prompt: "persist me", cwd: "/tmp/project" });
    const finished = await runs.waitForRun(created.id, 1_000);

    expect(finished.schemaVersion).toBe(RUN_SCHEMA_VERSION);
    expect(finished.sessionId).toBe("session-a");
    expect(finished.shortName).toBe("persist me");
    expect(finished.timeoutMs).toBe(21_600_000);
    expect(finished.project.path).toBe("/tmp/project");
    expect(finished.outputEvents.map((event) => [event.stream, event.text])).toEqual([
      ["stdout", "stored stdout"],
      ["stderr", "stored stderr"]
    ]);

    const sessionFile = await readFile(join(stateDir, "sessions", "session-a", "session.json"), "utf8");
    expect(JSON.parse(sessionFile)).toMatchObject({
      schemaVersion: "humanize2.session.v1",
      sessionId: "session-a"
    });

    const restoredStore = await FileRunStore.create({
      stateDir,
      sessionId: "session-b",
      now: () => "2026-05-12T22:00:00.000Z"
    });
    const restoredRuns = await restoredStore.loadRuns();

    expect(restoredRuns).toHaveLength(1);
    expect(restoredRuns[0]).toMatchObject({
      id: "run-a",
      schemaVersion: RUN_SCHEMA_VERSION,
      sessionId: "session-a",
      status: "succeeded",
      result: {
        stdout: "stored stdout"
      }
    });
    expect(restoredRuns[0].outputEvents).toHaveLength(2);
  });

  it("restores unfinished runs from previous sessions as interrupted", async () => {
    const stateDir = await tempDirectory();
    const store = await FileRunStore.create({
      stateDir,
      sessionId: "session-a",
      now: () => "2026-05-12T21:00:00.000Z"
    });
    await store.recordRunCreated({
      id: "run-interrupted",
      schemaVersion: RUN_SCHEMA_VERSION,
      sessionId: "session-a",
      shortName: "unfinished run",
      agent: "codex",
      prompt: "never finished",
      timeoutMs: 21_600_000,
      project: {
        path: "/tmp/project",
        git: {
          isRepo: false
        }
      },
      status: "running",
      createdAt: "2026-05-12T21:00:00.000Z",
      startedAt: "2026-05-12T21:00:00.000Z",
      outputEvents: []
    });

    const restoredStore = await FileRunStore.create({
      stateDir,
      sessionId: "session-b",
      now: () => "2026-05-12T22:00:00.000Z"
    });
    const restoredRuns = await restoredStore.loadRuns();

    expect(restoredRuns).toMatchObject([
      {
        id: "run-interrupted",
        status: "interrupted",
        error: "Hub session ended before this run finished"
      }
    ]);
  });
});
