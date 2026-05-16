import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import type { AgentBackend, AgentId, AgentRequest, AgentResult, AgentStatus } from "../src/agents/types.js";
import { AgentRunCoordinator } from "../src/hub/runs.js";
import { HumanizeService } from "../src/service.js";
import { WorkflowCoordinator } from "../src/workflows/coordinator.js";
import { restoreWorkflowRunsFromStore } from "../src/workflows/recovery.js";
import { FileWorkflowStore } from "../src/workflows/storage.js";
import type { WorkflowCartridge } from "../src/workflows/types.js";

const tempDirs: string[] = [];

afterEach(async () => {
  await Promise.all(tempDirs.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

describe("workflow storage", () => {
  it("loads current cartridge source path before the stored HTML fallback", async () => {
    const stateDir = await tempDirectory();
    const sourceDir = await tempDirectory();
    const sourcePath = join(sourceDir, "workflow.html");
    const storedHtml = "<h2-workflow id=\"source-backed-flow\"><h2-flow></h2-flow></h2-workflow>";
    const currentHtml = "<h2-workflow id=\"source-backed-flow\"><h2-flow><h2-loop id=\"implementation-loop\" max=\"1\" counter-label=\"Round\"></h2-loop></h2-flow></h2-workflow>";

    await writeFile(sourcePath, storedHtml, "utf8");
    const store = await FileWorkflowStore.create({ stateDir });
    store.recordCartridge(cartridgeRecord({
      id: "source-backed-flow",
      sourceHtml: storedHtml,
      sourcePath
    }));

    await writeFile(sourcePath, currentHtml, "utf8");

    await expect(store.loadCartridgeHtml("source-backed-flow")).resolves.toBe(currentHtml);
  });

  it("loads bundled first-party cartridge source before stale stored HTML", async () => {
    const stateDir = await tempDirectory();
    const store = await FileWorkflowStore.create({ stateDir });
    store.recordCartridge(cartridgeRecord({
      id: "rlcr",
      sourceHtml: "<h2-workflow id=\"rlcr\"><h2-flow><h2-loop id=\"implementation-loop\" max=\"42\"></h2-loop></h2-flow></h2-workflow>"
    }));

    const restoredHtml = await store.loadCartridgeHtml("rlcr");

    expect(restoredHtml).toContain("counter-label=\"Round\"");
  });

  it("persists workflow run snapshots with artifacts and boards", async () => {
    const stateDir = await tempDirectory();
    const store = await FileWorkflowStore.create({ stateDir });
    const workflows = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["workflow-run", "artifact-done"]),
      now: fixedClock(),
      store
    });
    const cartridge = await workflows.loadHtml({
      html: `
        <h2-workflow id="stored-flow" name="Stored Flow" version="0.1.0">
          <h2-state><h2-board id="scoreboard" schema="score.v1"></h2-board></h2-state>
          <h2-flow><h2-await id="done-wait" on="exists(artifact.done)"></h2-await></h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: cartridge.id });

    workflows.patchBoard({
      workflowRunId: run.id,
      boardId: "scoreboard",
      patch: { active: 1 }
    });
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "done",
      schema: "done.v1",
      producer: "test",
      content: { ok: true }
    });
    await workflows.waitForRun(run.id, 1_000);

    const restored = await store.loadRuns();
    expect(restored).toHaveLength(1);
    expect(restored[0]).toMatchObject({
      id: "workflow-run",
      cartridgeId: "stored-flow",
      status: "succeeded",
      boards: [{ id: "scoreboard", value: { active: 1 } }],
      artifacts: [{ id: "artifact-done", name: "done", content: { ok: true } }]
    });

    const snapshot = await store.loadSnapshot(run.id);
    expect((snapshot as any).storageSchemaVersion).toBe("humanize2.workflow.storage.v1");
  });

  it("rejects persisted workflow snapshots with an unsupported storage schema version", async () => {
    const stateDir = await tempDirectory();
    const store = await FileWorkflowStore.create({ stateDir });
    await mkdir(join(stateDir, "workflows", "snapshots"), { recursive: true });
    await writeFile(
      join(stateDir, "workflows", "snapshots", "bad-run.json"),
      JSON.stringify({
        schemaVersion: "humanize2.workflow.snapshot.v1",
        storageSchemaVersion: "humanize2.workflow.storage.v999",
        runId: "bad-run",
        cartridgeId: "stored-flow",
        frontier: [],
        inflight: [],
        completed: [],
        joinArrivals: [],
        loopIterations: [],
        agentRetryCounts: [],
        agentVertexState: [],
        pendingHumanRequests: [],
        emittedEventTypes: []
      }),
      "utf8"
    );

    await expect(store.loadSnapshot("bad-run")).rejects.toThrow(/storage schema|storage.v999/);
  });

  it("restores stored terminal workflow runs for dashboard listing", async () => {
    const stateDir = await tempDirectory();
    const store = await FileWorkflowStore.create({ stateDir });
    const workflows = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["workflow-run", "artifact-done"]),
      now: fixedClock(),
      store
    });
    const cartridge = await workflows.loadHtml({
      html: `
        <h2-workflow id="stored-view-flow" name="Stored View Flow" version="0.1.0">
          <h2-manifest>
            <h2-artifact name="done" schema="done.v1"></h2-artifact>
            <h2-view slot="properties"></h2-view>
          </h2-manifest>
          <h2-view slot="properties">
            <section><p data-h2-bind="artifact.done.status">waiting</p></section>
          </h2-view>
          <h2-flow><h2-await id="done-wait" on="exists(artifact.done)"></h2-await></h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: cartridge.id });
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "done",
      schema: "done.v1",
      producer: "test",
      content: { status: "ok" }
    });
    await workflows.waitForRun(run.id, 1_000);
    const storedRunPath = join(stateDir, "workflows", "runs", `${run.id}.json`);
    const storedRun = JSON.parse(await readFile(storedRunPath, "utf8")) as Record<string, unknown>;
    delete storedRun.loopIterations;
    delete storedRun.vars;
    await writeFile(storedRunPath, JSON.stringify(storedRun, null, 2), "utf8");

    const restoredStore = await FileWorkflowStore.create({ stateDir });
    const restoredWorkflows = new WorkflowCoordinator(emptyRunCoordinator(), { store: restoredStore });
    await restoreWorkflowRunsFromStore(restoredStore, restoredWorkflows);

    const restoredRuns = restoredWorkflows.listRunsWithRenderedViews();
    expect(restoredRuns).toHaveLength(1);
    expect(restoredRuns[0]).toMatchObject({
      id: "workflow-run",
      cartridgeId: "stored-view-flow",
      status: "succeeded"
    });
    expect(restoredRuns[0].views[0].html).toContain("ok");
  });
});

async function tempDirectory(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "humanize2-workflow-store-"));
  tempDirs.push(directory);
  return directory;
}

function emptyRunCoordinator(): AgentRunCoordinator {
  return new AgentRunCoordinator(new HumanizeService([
    fakeBackend("codex"),
    fakeBackend("claude")
  ]), {
    jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc"
  });
}

function cartridgeRecord(input: { id: string; sourceHtml: string; sourcePath?: string }): WorkflowCartridge {
  return {
    id: input.id,
    name: input.id,
    sourceHtml: input.sourceHtml,
    sourcePath: input.sourcePath,
    manifest: {
      agentTools: [],
      scriptAllowlist: [],
      artifactSchemas: [],
      declaresView: false,
      declaresHumanInput: false
    },
    boards: [],
    eventTypes: [],
    artifactTypes: [],
    templates: {},
    vars: [],
    views: [],
    nodes: [],
    loadEvents: []
  };
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
  return () => new Date(Date.UTC(2026, 4, 14, 20, 0, index++)).toISOString();
}
