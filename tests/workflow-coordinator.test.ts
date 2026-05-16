import { describe, expect, it } from "vitest";

import type { AgentBackend, AgentId, AgentRequest, AgentResult, AgentStatus } from "../src/agents/types.js";
import { buildAgentSessions } from "../src/hub/agent-sessions.js";
import { AgentRunCoordinator } from "../src/hub/runs.js";
import { HumanizeService } from "../src/service.js";
import { WorkflowCoordinator } from "../src/workflows/coordinator.js";

describe("WorkflowCoordinator", () => {
  it("runs the captain-worker intervention smoke flow as one workflow", async () => {
    const seenRequests: AgentRequest[] = [];
    const runIds = ["captain-run"];
    const runCoordinator = new AgentRunCoordinator(new HumanizeService([
      slowBackend("codex", seenRequests),
      slowBackend("claude", seenRequests)
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc",
      idFactory: () => {
        const next = runIds.shift();
        if (next === undefined) {
          throw new Error("missing test run id");
        }
        return next;
      }
    });
    const workflows = new WorkflowCoordinator(runCoordinator, {
      idFactory: ids(["workflow-run", "artifact-team"]),
      now: fixedClock()
    });
    const cartridge = await workflows.loadHtml({ html: teamFlowHtml(10), sourcePath: "flow/experimental/team-intervention-smoke/workflow.html" });

    const workflowRun = workflows.start({ cartridgeId: cartridge.id });
    await waitUntil(() => seenRequests.length >= 1);

    const requests = seenRequests.map((request) => request.prompt);
    expect(requests).toEqual([
      "Captain: coordinate team."
    ]);
    expect(runCoordinator.listRuns()).toHaveLength(1);
    const sessions = buildAgentSessions(runCoordinator.listRuns(), "2026-05-14T18:00:30.000Z");
    expect(sessions.map((session) => session.title)).toEqual([
      "captain"
    ]);

    const inflight = workflows.getRun(workflowRun.id);
    expect(["running", "waiting"]).toContain(inflight.status);

    workflows.deliverArtifact({
      workflowRunId: workflowRun.id,
      name: "team-summary",
      schema: "team.captainResult.v1",
      producer: "captain",
      content: { status: "ok", finalTasks: "D/E/F" }
    });

    const finished = await workflows.waitForRun(workflowRun.id, 1_000);
    expect(finished).toMatchObject({
      id: "workflow-run",
      cartridgeId: "team-intervention-smoke",
      status: "succeeded"
    });
    expect(finished.artifacts.map((artifact) => artifact.name)).toEqual([
      "team-summary"
    ]);
    expect(finished.boards).toMatchObject([
      { id: "team-board", value: { status: "ok", finalTasks: "D/E/F" } }
    ]);
    expect(finished.events.map((event) => event.type)).toContain("workflow.succeeded");
  });

  it("patches workflow boards through Humanize2 state", async () => {
    const workflows = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["workflow-run"]),
      now: fixedClock()
    });
    const cartridge = await workflows.loadHtml({
      html: `
        <h2-workflow id="board-flow" name="Board Flow" version="0.1.0">
          <h2-state><h2-board id="scoreboard" schema="score.v1"></h2-board></h2-state>
          <h2-flow></h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: cartridge.id });

    const board = workflows.patchBoard({
      workflowRunId: run.id,
      boardId: "scoreboard",
      patch: { completed: 2, active: ["worker-1"] }
    });

    expect(board).toMatchObject({
      id: "scoreboard",
      schema: "score.v1",
      value: { completed: 2, active: ["worker-1"] }
    });
    expect(workflows.getBoard({ workflowRunId: run.id, boardId: "scoreboard" })).toEqual(board);
  });

  it("reads the latest artifact when a workflow has repeated artifact names", async () => {
    const workflows = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["workflow-run", "artifact-first", "artifact-second"]),
      now: fixedClock()
    });
    const cartridge = await workflows.loadHtml({
      html: `
        <h2-workflow id="artifact-read-flow" name="Artifact Read Flow" version="0.1.0">
          <h2-flow></h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: cartridge.id });

    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "round-summary",
      producer: "builder",
      content: { iteration: 1 }
    });
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "round-summary",
      producer: "builder",
      content: { iteration: 2 }
    });

    expect(workflows.getArtifact({
      workflowRunId: run.id,
      name: "round-summary"
    })).toMatchObject({
      id: "artifact-second",
      content: { iteration: 2 }
    });
  });

  it("clears stale wait targets when loading terminal workflow runs", () => {
    const workflows = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["workflow-run"]),
      now: fixedClock()
    });

    const loaded = workflows.loadStoredRun({
      run: {
        id: "workflow-run",
        cartridgeId: "stored-flow",
        cartridgeName: "Stored Flow",
        status: "succeeded",
        createdAt: "2026-05-14T18:00:00.000Z",
        startedAt: "2026-05-14T18:00:00.000Z",
        finishedAt: "2026-05-14T18:01:00.000Z",
        waitingFor: [{ kind: "artifact", name: "done", vertex: "worker" }],
        nodeRunIds: {},
        boards: [],
        artifacts: [],
        views: [],
        events: [],
        loopIterations: {},
        vars: {}
      }
    });

    expect(loaded.waitingFor).toEqual([]);
  });

  it("routes branch cases to workflow nodes by artifact data", async () => {
    const seenRequests: AgentRequest[] = [];
    const workflows = new WorkflowCoordinator(new AgentRunCoordinator(new HumanizeService([
      slowBackend("codex", seenRequests),
      slowBackend("claude", seenRequests)
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc",
      idFactory: ids(["worker-run"])
    }), {
      idFactory: ids(["workflow-run", "route-artifact"]),
      now: fixedClock()
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="branch-flow" name="Branch Flow" version="0.1.0">
          <h2-manifest>
            <h2-capability name="agent" tools="codex"></h2-capability>
          </h2-manifest>
          <h2-template id="worker-prompt">Worker route selected.</h2-template>
          <h2-flow>
            <h2-await id="route-wait" on="exists(artifact.route)"></h2-await>
            <h2-branch on="artifact.route.next">
              <h2-case value="worker" goto="worker-node"></h2-case>
              <h2-default goto="worker-node"></h2-default>
            </h2-branch>
            <h2-agent id="worker-node" tool="codex" prompt="#worker-prompt" short-name="branch-worker"></h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    });

    const run = workflows.start({ cartridgeId: "branch-flow" });
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "route",
      schema: "route.v1",
      content: { next: "worker" }
    });
    await waitUntil(() => seenRequests.length === 1);
    const finished = await workflows.waitForRun(run.id, 1_000);

    expect(seenRequests.map((request) => request.prompt)).toEqual(["Worker route selected."]);
    expect(finished.events).toEqual(expect.arrayContaining([
      expect.objectContaining({
        type: "branch.routed",
        data: expect.objectContaining({ target: "worker-node" })
      })
    ]));
  });

  it("scopes artifact references to the current loop iteration and resolves @iter-N qualifiers", async () => {
    const workflows = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["workflow-run", "artifact-1", "artifact-2", "artifact-3"]),
      now: fixedClock()
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="iter-flow" name="Iter Flow" version="0.1.0">
          <h2-state><h2-board id="snapshot" schema="snapshot.v1"></h2-board></h2-state>
          <h2-flow>
            <h2-loop id="round" max="2">
              <h2-await id="round-result-await" on="exists(artifact.result)"></h2-await>
              <h2-transform id="record-current" from="artifact.result" to="board.snapshot"></h2-transform>
            </h2-loop>
            <h2-transform id="record-final" from="artifact.result@iter-2" to="board.snapshot"></h2-transform>
          </h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: "iter-flow" });
    await waitUntil(() => workflows.getRun(run.id).waitingFor.some((target) => target.kind === "predicate"));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "result",
      content: { stage: "first" }
    });
    await waitUntil(() => workflows.getRun(run.id).events.filter((event) => event.type === "loop.iteration_started").length >= 2);
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "result",
      content: { stage: "second" }
    });
    const finished = await workflows.waitForRun(run.id, 1_000);
    expect(finished.status).toBe("succeeded");
    expect(finished.boards).toMatchObject([
      { id: "snapshot", value: { stage: "second" } }
    ]);
    expect(finished.artifacts.map((artifact) => artifact.iteration)).toEqual([1, 2]);
  });

  it("uses the latest accepted artifact for current loop iteration branch routing", async () => {
    const workflows = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["workflow-run", "artifact-1", "artifact-2"]),
      now: fixedClock()
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="duplicate-current-artifact" name="Duplicate Current Artifact" version="0.1.0">
          <h2-manifest>
            <h2-capability name="artifact" schemas="plan.verdict.v1"></h2-capability>
          </h2-manifest>
          <h2-flow>
            <h2-loop id="round" max="1">
              <h2-sleep id="hold-open" duration-ms="25"></h2-sleep>
              <h2-branch id="route" on="artifact.route.status">
                <h2-case value="converged" goto="ok-end"></h2-case>
                <h2-default goto="bad-end"></h2-default>
              </h2-branch>
              <h2-end id="ok-end"></h2-end>
              <h2-end id="bad-end"></h2-end>
            </h2-loop>
          </h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: "duplicate-current-artifact" });
    await waitUntil(() => workflows.getRun(run.id).events.some((event) => event.type === "loop.iteration_started"));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "route",
      schema: "plan.verdict.v1",
      producer: "reviewer",
      content: "{\"status\":\"converged\"}"
    });
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "route",
      schema: "plan.verdict.v1",
      producer: "reviewer",
      content: { status: "converged" }
    });
    const finished = await workflows.waitForRun(run.id, 1_000);

    expect(finished.status).toBe("succeeded");
    expect(finished.events).toEqual(expect.arrayContaining([
      expect.objectContaining({
        type: "branch.routed",
        data: expect.objectContaining({ branchId: "route", target: "ok-end" })
      })
    ]));
  });

  it("drives soft-enforcement retry up to the configured cap and then fails the workflow", async () => {
    const seenRequests: AgentRequest[] = [];
    const runCoordinator = new AgentRunCoordinator(new HumanizeService([
      slowBackend("codex", seenRequests),
      slowBackend("claude", seenRequests)
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc",
      idFactory: ids(["builder-run", "builder-retry-1", "builder-retry-2"])
    });
    const workflows = new WorkflowCoordinator(runCoordinator, {
      idFactory: ids(["workflow-run"]),
      now: fixedClock(),
      softEnforcementRetryMax: 2
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="retry-flow" name="Retry Flow" version="0.1.0">
          <h2-manifest>
            <h2-capability name="agent" tools="codex"></h2-capability>
          </h2-manifest>
          <h2-template id="builder-prompt">Builder: deliver result.</h2-template>
          <h2-flow>
            <h2-agent id="builder" tool="codex" prompt="#builder-prompt" short-name="builder">
              <h2-expect artifact="result" schema="result.v1"></h2-expect>
            </h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: "retry-flow" });
    const finished = await workflows.waitForRun(run.id, 2_000);
    expect(finished.status).toBe("failed");
    const retryEvents = finished.events.filter((event) => event.type === "agent.expectation_retry");
    expect(retryEvents).toHaveLength(2);
    expect(finished.events.some((event) => event.type === "vertex.failed" && (event.data as { reason?: string }).reason === "agent.expectation_unmet")).toBe(true);
  });

  it("accepts an expected artifact when the producer uses the agent short name alias", async () => {
    const seenRequests: AgentRequest[] = [];
    const runCoordinator = new AgentRunCoordinator(new HumanizeService([
      slowBackend("codex", seenRequests)
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc",
      idFactory: ids(["workflow-run", "worker-run"])
    });
    const workflows = new WorkflowCoordinator(runCoordinator, {
      idFactory: ids(["workflow-run", "artifact-result"]),
      now: fixedClock()
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="producer-alias" name="Producer Alias" version="0.1.0">
          <h2-manifest>
            <h2-capability name="agent" tools="codex"></h2-capability>
          </h2-manifest>
          <h2-template id="worker-prompt">Worker: deliver result.</h2-template>
          <h2-flow>
            <h2-agent id="worker-node" tool="codex" prompt="#worker-prompt" short-name="friendly-worker">
              <h2-expect artifact="result" schema="result.v1"></h2-expect>
            </h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    });

    const run = workflows.start({ cartridgeId: "producer-alias" });
    await waitUntil(() => seenRequests.length >= 1);
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "result",
      schema: "result.v1",
      producer: "friendly-worker",
      content: { status: "ok" }
    });

    const finished = await workflows.waitForRun(run.id, 1_000);
    expect(finished.status).toBe("succeeded");
    expect(finished.artifacts.map((artifact) => artifact.producer)).toEqual(["friendly-worker"]);
    expect(finished.events).toEqual(expect.arrayContaining([
      expect.objectContaining({
        type: "agent.expectation_satisfied",
        data: expect.objectContaining({
          nodeId: "worker-node",
          artifact: "result"
        })
      })
    ]));
  });

  it("resolves an h2-await on event.<type> only when the matching event arrives after the await enters inflight", async () => {
    const workflows = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["workflow-run"]),
      now: fixedClock()
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="event-end-to-end" name="Event End To End" version="0.1.0">
          <h2-flow>
            <h2-await id="event-wait" on="event.[custom.done]"></h2-await>
          </h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: "event-end-to-end" });
    await waitUntil(() => workflows.getRun(run.id).waitingFor.some((target) => target.kind === "predicate" && target.expression.includes("custom.done")));
    workflows.emitEvent({ workflowRunId: run.id, type: "custom.done" });
    const final = await workflows.waitForRun(run.id, 1_000);
    expect(final.status).toBe("succeeded");
  });

  it("does not satisfy an h2-await on event.<type> when the event was emitted before the await entered inflight", async () => {
    const workflows = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["workflow-run"]),
      now: fixedClock()
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="event-baseline" name="Event Baseline" version="0.1.0">
          <h2-flow>
            <h2-await id="baseline-wait" on="event.[custom.done]" timeout-ms="80"></h2-await>
          </h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: "event-baseline" });
    // Emit `custom.done` synchronously after start but before the microtask
    // tick fires, so the await captures a baseline that already contains the
    // event. The predicate must therefore NOT see it.
    workflows.emitEvent({ workflowRunId: run.id, type: "custom.done" });
    const final = await workflows.waitForRun(run.id, 1_000);
    expect(final.status).toBe("failed");
    expect(final.events.some((event) =>
      event.type === "vertex.failed" &&
      (event.data as { reason?: string }).reason === "await.timeout"
    )).toBe(true);
  });

  it("executes checks, transforms, human requests, and bounded loops", async () => {
    const workflows = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["workflow-run", "answer-artifact"]),
      now: fixedClock()
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="primitive-flow" name="Primitive Flow" version="0.1.0">
          <h2-manifest>
            <h2-capability name="script" allow="test.pass,test.copy"></h2-capability>
          </h2-manifest>
          <h2-state><h2-board id="scoreboard" schema="score.v1"></h2-board></h2-state>
          <h2-flow>
            <h2-check id="preflight" uses="test.pass"></h2-check>
            <h2-human id="quiz" prompt="Confirm the plan" artifact="quiz-answer" schema="quiz.v1"></h2-human>
            <h2-loop id="bounded-loop" max="2">
              <h2-transform id="score-update" from="artifact.quiz-answer" to="board.scoreboard" uses="test.copy"></h2-transform>
            </h2-loop>
          </h2-flow>
        </h2-workflow>
      `
    });

    const run = workflows.start({ cartridgeId: "primitive-flow" });
    await waitUntil(() => workflows.getRun(run.id).waitingFor.some((target) =>
      target.kind === "human" && target.artifact === "quiz-answer"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "quiz-answer",
      schema: "quiz.v1",
      content: { confirmed: true }
    });
    const finished = await workflows.waitForRun(run.id, 1_000);

    expect(finished.status).toBe("succeeded");
    expect(finished.boards).toMatchObject([{ id: "scoreboard", value: { confirmed: true } }]);
    expect(finished.events.map((event) => event.type)).toEqual(expect.arrayContaining([
      "check.completed",
      "human.requested",
      "loop.iteration_started",
      "transform.completed"
    ]));
    expect(finished.events.filter((event) => event.type === "loop.iteration_started")).toHaveLength(2);
  });
});

function teamFlowHtml(waitMs: number): string {
  return `
    <h2-workflow id="team-intervention-smoke" name="Team Intervention Smoke" version="0.1.0">
      <h2-manifest>
        <h2-capability name="agent" tools="codex,claude"></h2-capability>
        <h2-capability name="artifact" schemas="team.captainResult.v1"></h2-capability>
      </h2-manifest>
      <h2-state>
        <h2-board id="team-board" schema="team.board.v1"></h2-board>
      </h2-state>
      <h2-template id="captain-prompt">Captain: coordinate team.</h2-template>
      <h2-flow>
        <h2-agent id="captain" tool="codex" prompt="#captain-prompt" short-name="captain">
          <h2-expect artifact="team-summary" schema="team.captainResult.v1"></h2-expect>
        </h2-agent>
        <h2-transform id="team-board-result" from="artifact.team-summary" to="board.team-board"></h2-transform>
      </h2-flow>
    </h2-workflow>
  `;
}

function slowBackend(id: AgentId, seenRequests: AgentRequest[]): AgentBackend {
  return {
    id,
    displayName: `${id} slow backend`,
    async status(): Promise<AgentStatus> {
      return {
        agent: id,
        displayName: `${id} slow backend`,
        available: true,
        version: `${id}-test`
      };
    },
    async run(request: AgentRequest): Promise<AgentResult> {
      seenRequests.push(request);
      const backendSessionId = request.resumeSessionId ?? `${id}-${seenRequests.length}`;
      request.onOutput?.({ stream: "stdout", text: `{"type":"thread.started","session_id":"${backendSessionId}"}\n` });
      await new Promise<void>((resolve) => {
        const timeout = setTimeout(resolve, request.prompt.includes("change to final") ? 1 : 200);
        request.signal?.addEventListener("abort", () => {
          clearTimeout(timeout);
          resolve();
        }, { once: true });
      });
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
        cwd: request.cwd,
        backendSessionId
      };
    }
  };
}

function emptyRunCoordinator(): AgentRunCoordinator {
  return new AgentRunCoordinator(new HumanizeService([
    slowBackend("codex", []),
    slowBackend("claude", [])
  ]), {
    jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc"
  });
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
  return () => new Date(Date.UTC(2026, 4, 14, 18, 0, index++)).toISOString();
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
