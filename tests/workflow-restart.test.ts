import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import type { AgentBackend, AgentId, AgentRequest, AgentResult, AgentStatus } from "../src/agents/types.js";
import { AgentRunCoordinator } from "../src/hub/runs.js";
import { HumanizeService } from "../src/service.js";
import { WorkflowCoordinator } from "../src/workflows/coordinator.js";
import { FileWorkflowStore } from "../src/workflows/storage.js";

const tempDirs: string[] = [];

afterEach(async () => {
  await Promise.all(tempDirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

describe("workflow restart recovery", () => {
  it("restores an in-flight workflow blocked on h2-await and completes after artifact delivery", async () => {
    const stateDir = await makeTempDir();
    const store = await FileWorkflowStore.create({ stateDir });

    const beforeRestart = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["workflow-run"]),
      now: fixedClock(),
      store
    });

    const cartridge = await beforeRestart.loadHtml({
      html: `
        <h2-workflow id="restart-flow" name="Restart Flow" version="0.1.0">
          <h2-flow>
            <h2-await id="done-wait" on="exists(artifact.done)"></h2-await>
          </h2-flow>
        </h2-workflow>
      `
    });
    const startedRun = beforeRestart.start({ cartridgeId: cartridge.id });
    await waitUntil(() => beforeRestart.getRun(startedRun.id).waitingFor.some((target) => target.kind === "predicate"));

    const snapshot = await store.loadSnapshot(startedRun.id);
    expect(snapshot).toBeDefined();
    expect(snapshot?.frontier.length).toBeGreaterThanOrEqual(0);
    expect(snapshot?.inflight).toContain("done-wait");

    const persistedRun = beforeRestart.getRun(startedRun.id);

    const afterRestart = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["artifact-done"]),
      now: fixedClock(),
      store
    });
    await afterRestart.restoreRun({
      run: persistedRun,
      cartridge,
      snapshot: snapshot!
    });
    afterRestart.deliverArtifact({
      workflowRunId: persistedRun.id,
      name: "done",
      content: { ok: true }
    });
    const final = await afterRestart.waitForRun(persistedRun.id, 1_000);
    expect(final.status).toBe("succeeded");
    expect(final.events.map((event) => event.type)).toContain("workflow.restored");
  });
});

async function makeTempDir(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "humanize2-workflow-restart-"));
  tempDirs.push(dir);
  return dir;
}

function emptyRunCoordinator(): AgentRunCoordinator {
  return new AgentRunCoordinator(new HumanizeService([
    fakeBackend("codex"),
    fakeBackend("claude")
  ]), {
    jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc"
  });
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
      return {
        agent: id,
        success: true,
        exitCode: 0,
        signal: null,
        stdout: `handled ${request.prompt}`,
        stderr: "",
        durationMs: 1,
        timedOut: false,
        command: id,
        args: [request.prompt],
        cwd: request.cwd
      };
    }
  };
}

function ids(values: string[]): () => string {
  return () => {
    const next = values.shift();
    if (next === undefined) {
      throw new Error("missing test id");
    }
    return next;
  };
}

function fixedClock(): () => string {
  let index = 0;
  return () => new Date(Date.UTC(2026, 4, 14, 21, 0, index++)).toISOString();
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt > 1_000) {
      throw new Error("timed out waiting for test condition");
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
