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

describe("Gap 2: nested loop reset uses bodyVertexIds", () => {
  it("runs an outer loop max=2 containing an inner loop max=2 four total inner iterations and succeeds", async () => {
    const workflows = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["workflow-run"]),
      now: fixedClock()
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="nested-loop-flow" name="Nested" version="0.1.0">
          <h2-manifest>
            <h2-capability name="script" allow="test.pass"></h2-capability>
          </h2-manifest>
          <h2-flow>
            <h2-loop id="outer" max="2">
              <h2-loop id="inner" max="2">
                <h2-script id="inner-body" uses="test.pass"></h2-script>
              </h2-loop>
            </h2-loop>
          </h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: "nested-loop-flow" });
    const finished = await workflows.waitForRun(run.id, 2_000);
    expect(finished.status).toBe("succeeded");
    const innerStarts = finished.events.filter((event) =>
      event.type === "loop.iteration_started" &&
      (event.data as { loopId?: string }).loopId === "inner"
    );
    expect(innerStarts).toHaveLength(4);
    const outerStarts = finished.events.filter((event) =>
      event.type === "loop.iteration_started" &&
      (event.data as { loopId?: string }).loopId === "outer"
    );
    expect(outerStarts).toHaveLength(2);
  });
});

describe("Gap 3: event.<type> predicate scoped to await-entry window", () => {
  it("unblocks h2-await on=event.<type> when matching event is emitted after entry", async () => {
    const workflows = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["workflow-run"]),
      now: fixedClock()
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="event-await" name="Event Await" version="0.1.0">
          <h2-flow>
            <h2-await id="wait-event" on="event.[custom.done]"></h2-await>
          </h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: "event-await" });
    await waitUntil(() => workflows.getRun(run.id).waitingFor.some((target) => target.kind === "predicate"));
    workflows.emitEvent({ workflowRunId: run.id, type: "custom.done" });
    const final = await workflows.waitForRun(run.id, 1_000);
    expect(final.status).toBe("succeeded");
  });

  it("rejects parser when event.<type> is used inside h2-loop while or h2-branch on", async () => {
    const workflows = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["workflow-run"]),
      now: fixedClock()
    });
    await expect(workflows.loadHtml({
      html: `
        <h2-workflow id="bad-event-branch" name="Bad Event" version="0.1.0">
          <h2-flow>
            <h2-script id="left" uses="test.pass"></h2-script>
            <h2-branch on="event.foo">
              <h2-case value="x" goto="left"></h2-case>
              <h2-default goto="left"></h2-default>
            </h2-branch>
          </h2-flow>
        </h2-workflow>
      `
    })).rejects.toThrow(/event_root_outside_await|event\.<type>/);

    await expect(workflows.loadHtml({
      html: `
        <h2-workflow id="bad-event-loop" name="Bad Event Loop" version="0.1.0">
          <h2-flow>
            <h2-loop id="bad" max="1" while="event.go">
              <h2-script id="body" uses="test.pass"></h2-script>
            </h2-loop>
          </h2-flow>
        </h2-workflow>
      `
    })).rejects.toThrow(/event_root_outside_await|event\.<type>/);
  });
});

describe("Gap 5: manifest requires explicit agent/script capabilities", () => {
  it("rejects load when h2-agent is used but manifest has no agent capability", async () => {
    const workflows = newCoordinator();
    await expect(workflows.loadHtml({
      html: `
        <h2-workflow id="no-agent-cap" name="No Agent Cap" version="0.1.0">
          <h2-manifest></h2-manifest>
          <h2-template id="p">Do.</h2-template>
          <h2-flow>
            <h2-agent id="builder" tool="codex" prompt="#p"></h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    })).rejects.toThrow(/tool_undeclared|manifest does not declare/);
  });

  it("rejects load when h2-script is used but manifest has no script capability", async () => {
    const workflows = newCoordinator();
    await expect(workflows.loadHtml({
      html: `
        <h2-workflow id="no-script-cap" name="No Script Cap" version="0.1.0">
          <h2-manifest></h2-manifest>
          <h2-flow>
            <h2-script id="run" uses="git.statusClean"></h2-script>
          </h2-flow>
        </h2-workflow>
      `
    })).rejects.toThrow(/script_undeclared|manifest does not declare/);
  });

  it("rejects load when h2-check is used but manifest has no script capability", async () => {
    const workflows = newCoordinator();
    await expect(workflows.loadHtml({
      html: `
        <h2-workflow id="no-check-cap" name="No Check Cap" version="0.1.0">
          <h2-manifest></h2-manifest>
          <h2-flow>
            <h2-check id="check" uses="git.statusClean"></h2-check>
          </h2-flow>
        </h2-workflow>
      `
    })).rejects.toThrow(/script_undeclared|manifest does not declare/);
  });
});

describe("Gap 6: agent expectations match by producer, schema, iteration, and validation status", () => {
  it("does not satisfy expectation when artifact is delivered by the wrong producer vertex", async () => {
    const workflows = new WorkflowCoordinator(slowRunCoordinator(), {
      idFactory: ids(["workflow-run", "artifact-1"]),
      now: fixedClock(),
      softEnforcementRetryMax: 0
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="producer-mismatch" name="Producer Mismatch" version="0.1.0">
          <h2-manifest>
            <h2-capability name="agent" tools="codex"></h2-capability>
            <h2-capability name="artifact" schemas="result.v1"></h2-capability>
          </h2-manifest>
          <h2-template id="p">Builder.</h2-template>
          <h2-flow>
            <h2-agent id="builder" tool="codex" prompt="#p">
              <h2-expect artifact="result" schema="result.v1"></h2-expect>
            </h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: "producer-mismatch" });
    // Pre-deliver via wrong producer right after start
    await waitUntil(() => workflows.getRun(run.id).events.some((event) => event.type === "agent.started"));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "result",
      schema: "result.v1",
      producer: "intruder",
      content: { ok: true }
    });
    const finished = await workflows.waitForRun(run.id, 2_000);
    expect(finished.status).toBe("failed");
    expect(finished.events.some((event) =>
      event.type === "vertex.failed" &&
      (event.data as { reason?: string }).reason === "agent.expectation_unmet"
    )).toBe(true);
  });

  it("does not satisfy expectation when artifact is delivered with wrong schema", async () => {
    const workflows = new WorkflowCoordinator(slowRunCoordinator(), {
      idFactory: ids(["workflow-run", "artifact-1"]),
      now: fixedClock(),
      softEnforcementRetryMax: 0
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="schema-mismatch-flow" name="Schema Mismatch" version="0.1.0">
          <h2-manifest>
            <h2-capability name="agent" tools="codex"></h2-capability>
            <h2-capability name="artifact" schemas="result.v1,wrong.v1"></h2-capability>
          </h2-manifest>
          <h2-template id="p">Builder.</h2-template>
          <h2-flow>
            <h2-agent id="builder" tool="codex" prompt="#p">
              <h2-expect artifact="result" schema="result.v1"></h2-expect>
            </h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: "schema-mismatch-flow" });
    await waitUntil(() => workflows.getRun(run.id).events.some((event) => event.type === "agent.started"));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "result",
      schema: "wrong.v1",
      producer: "builder",
      content: { ok: true }
    });
    const finished = await workflows.waitForRun(run.id, 2_000);
    expect(finished.status).toBe("failed");
    expect(finished.events.some((event) =>
      event.type === "vertex.failed" &&
      (event.data as { reason?: string }).reason === "agent.expectation_unmet"
    )).toBe(true);
  });

  it("satisfies expectation when accepted artifact is delivered by the producing vertex with matching schema", async () => {
    const workflows = new WorkflowCoordinator(slowRunCoordinator(), {
      idFactory: ids(["workflow-run", "artifact-1"]),
      now: fixedClock(),
      softEnforcementRetryMax: 0
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="accept-flow" name="Accept" version="0.1.0">
          <h2-manifest>
            <h2-capability name="agent" tools="codex"></h2-capability>
            <h2-capability name="artifact" schemas="result.v1"></h2-capability>
          </h2-manifest>
          <h2-template id="p">Builder.</h2-template>
          <h2-flow>
            <h2-agent id="builder" tool="codex" prompt="#p">
              <h2-expect artifact="result" schema="result.v1"></h2-expect>
            </h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: "accept-flow" });
    await waitUntil(() => workflows.getRun(run.id).events.some((event) => event.type === "agent.started"));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "result",
      schema: "result.v1",
      producer: "builder",
      content: { ok: true }
    });
    const finished = await workflows.waitForRun(run.id, 2_000);
    expect(finished.status).toBe("succeeded");
  });

  it("rejects duplicate artifact deliveries from non-producing vertices when an expectation is in flight", async () => {
    const workflows = new WorkflowCoordinator(slowRunCoordinator(), {
      idFactory: ids(["workflow-run", "artifact-1", "artifact-2"]),
      now: fixedClock(),
      softEnforcementRetryMax: 0
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="dup-delivery" name="Dup" version="0.1.0">
          <h2-manifest>
            <h2-capability name="agent" tools="codex"></h2-capability>
            <h2-capability name="artifact" schemas="result.v1"></h2-capability>
          </h2-manifest>
          <h2-template id="p">Builder.</h2-template>
          <h2-flow>
            <h2-agent id="builder" tool="codex" prompt="#p">
              <h2-expect artifact="result" schema="result.v1"></h2-expect>
            </h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: "dup-delivery" });
    await waitUntil(() => workflows.getRun(run.id).events.some((event) => event.type === "agent.started"));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "result",
      schema: "result.v1",
      producer: "intruder",
      content: { ok: false }
    });
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "result",
      schema: "result.v1",
      producer: "builder",
      content: { ok: true }
    });
    const finished = await workflows.waitForRun(run.id, 2_000);
    expect(finished.status).toBe("succeeded");
    expect(finished.events.some((event) => event.type === "artifact.double_delivery")).toBe(true);
  });
});

describe("Gap 1: logical agent run chain transfers terminal wait to continuation", () => {
  it("treats interruption of a running worker by h2-message as a logical continuation, not failure", async () => {
    const seenRequests: AgentRequest[] = [];
    const runCoordinator = new AgentRunCoordinator(new HumanizeService([
      slowBackend("codex", seenRequests, { initialDelayMs: 80, continuationDelayMs: 5 }),
      slowBackend("claude", seenRequests, { initialDelayMs: 80, continuationDelayMs: 5 })
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc"
    });
    const workflows = new WorkflowCoordinator(runCoordinator, {
      idFactory: ids(["workflow-run", "artifact-1"]),
      now: fixedClock()
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="intervene-running" name="Intervene Running" version="0.1.0">
          <h2-manifest>
            <h2-capability name="agent" tools="codex,claude"></h2-capability>
            <h2-capability name="artifact" schemas="result.v1"></h2-capability>
          </h2-manifest>
          <h2-template id="initial">Worker: initial task A.</h2-template>
          <h2-template id="redirect">Worker: change to task D.</h2-template>
          <h2-flow>
            <h2-parallel id="branches">
              <h2-agent id="worker" tool="codex" prompt="#initial" short-name="worker-a" timeout="10s">
                <h2-expect artifact="result" schema="result.v1"></h2-expect>
              </h2-agent>
              <h2-sequence id="captain-branch">
                <h2-sleep id="brief" duration-ms="10"></h2-sleep>
                <h2-message id="intervene" target="worker" prompt="#redirect" short-name="worker-d"></h2-message>
              </h2-sequence>
            </h2-parallel>
          </h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: "intervene-running" });
    await waitUntil(() => workflows.getRun(run.id).events.some((event) => event.type === "agent.message_sent"));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "result",
      schema: "result.v1",
      producer: "worker",
      content: { ok: true }
    });
    const finished = await workflows.waitForRun(run.id, 4_000);
    expect(finished.status).toBe("succeeded");
    // The original run was interrupted; the continuation run completed normally.
    const initialRun = runCoordinator.listRuns().find((record) => record.shortName === "worker-a");
    expect(initialRun?.status).toBe("interrupted");
  });
});

describe("Gap 7: storage recovery reconciles inflight agent vertices", () => {
  it("fails the workflow with agent.unrecoverable_after_restart when the managed run is missing on restore", async () => {
    const stateDir = await makeTempDir();
    const store = await FileWorkflowStore.create({ stateDir });
    const before = new WorkflowCoordinator(slowRunCoordinator(), {
      idFactory: ids(["workflow-run"]),
      now: fixedClock(),
      store
    });
    const cartridge = await before.loadHtml({
      html: `
        <h2-workflow id="restore-agent" name="Restore Agent" version="0.1.0">
          <h2-manifest>
            <h2-capability name="agent" tools="codex"></h2-capability>
            <h2-capability name="artifact" schemas="result.v1"></h2-capability>
          </h2-manifest>
          <h2-template id="p">Builder.</h2-template>
          <h2-flow>
            <h2-agent id="builder" tool="codex" prompt="#p">
              <h2-expect artifact="result" schema="result.v1"></h2-expect>
            </h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    });
    const startedRun = before.start({ cartridgeId: cartridge.id });
    await waitUntil(() => before.getRun(startedRun.id).events.some((event) => event.type === "agent.started"));
    const snapshot = await store.loadSnapshot(startedRun.id);
    expect(snapshot).toBeDefined();
    const persistedRun = before.getRun(startedRun.id);

    const after = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["unused"]),
      now: fixedClock(),
      store
    });
    await after.restoreRun({ run: persistedRun, cartridge, snapshot: snapshot! });
    const final = await after.waitForRun(persistedRun.id, 1_500);
    expect(final.status).toBe("failed");
    expect(final.events.some((event) =>
      event.type === "vertex.failed" &&
      (event.data as { reason?: string }).reason === "agent.unrecoverable_after_restart"
    )).toBe(true);
  });
});

describe("Gap 8: snapshot persistence on every scheduler mutation", () => {
  it("persists pendingHumanRequests entered via updateWaitingFor across restart", async () => {
    const stateDir = await makeTempDir();
    const store = await FileWorkflowStore.create({ stateDir });
    const before = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["workflow-run"]),
      now: fixedClock(),
      store
    });
    const cartridge = await before.loadHtml({
      html: `
        <h2-workflow id="human-restore" name="Human Restore" version="0.1.0">
          <h2-manifest>
            <h2-capability name="human-input"></h2-capability>
          </h2-manifest>
          <h2-flow>
            <h2-human id="ask" prompt="Pick" artifact="answer"></h2-human>
          </h2-flow>
        </h2-workflow>
      `
    });
    const startedRun = before.start({ cartridgeId: cartridge.id });
    await waitUntil(() => before.getRun(startedRun.id).waitingFor.some((target) => target.kind === "human"));
    const snapshot = await store.loadSnapshot(startedRun.id);
    expect(snapshot).toBeDefined();
    expect(snapshot!.pendingHumanRequests.some((target) =>
      target.kind === "human" && target.artifact === "answer"
    )).toBe(true);

    const persistedRun = before.getRun(startedRun.id);
    const after = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["answer-1"]),
      now: fixedClock(),
      store
    });
    await after.restoreRun({ run: persistedRun, cartridge, snapshot: snapshot! });
    after.deliverArtifact({ workflowRunId: persistedRun.id, name: "answer", content: { ok: true } });
    const final = await after.waitForRun(persistedRun.id, 1_500);
    expect(final.status).toBe("succeeded");
  });
});

describe("Gap 9: RLCR cartridge complete path does not fall through to stop sink", () => {
  it("complete route executes code-review and finalizer without firing the stop sink", async () => {
    const seenRequests: AgentRequest[] = [];
    const runCoordinator = new AgentRunCoordinator(new HumanizeService([
      slowBackend("codex", seenRequests, { initialDelayMs: 80, continuationDelayMs: 20 }),
      slowBackend("claude", seenRequests, { initialDelayMs: 80, continuationDelayMs: 20 })
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc"
    });
    const workflows = new WorkflowCoordinator(runCoordinator, {
      idFactory: ids(["workflow-run", "implementation-plan", "plan-compliance", "plan-quiz", "plan-quiz-answer", "round-summary", "review-verdict", "code-review-result", "rlcr-final"]),
      now: fixedClock()
    });
    const html = await readFlow("flow/rlcr/workflow.html");
    await workflows.loadHtml({
      html,
      sourcePath: "flow/rlcr/workflow.html"
    });

    const run = workflows.start({ cartridgeId: "rlcr" });
    // Deliver implementation plan
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "implementation-plan",
      schema: "rlcr.plan.v1",
      producer: "human",
      content: { steps: ["a"] }
    });
    await waitUntil(() => workflows.getRun(run.id).events.some((event) =>
      event.type === "agent.started" &&
      (event.data as { nodeId?: string }).nodeId === "plan-compliance-checker"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-compliance",
      schema: "rlcr.planCompliance.v1",
      producer: "plan-compliance-checker",
      content: { status: "pass" }
    });
    await waitUntil(() => workflows.getRun(run.id).events.some((event) =>
      event.type === "agent.started" &&
      (event.data as { nodeId?: string }).nodeId === "plan-quiz-generator"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-quiz",
      schema: "rlcr.quiz.v1",
      producer: "plan-quiz-generator",
      content: { questions: [] }
    });
    // Deliver the quiz answer (h2-human)
    await waitUntil(() => workflows.getRun(run.id).waitingFor.some((target) =>
      target.kind === "human" && target.artifact === "plan-quiz-answer"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-quiz-answer",
      schema: "rlcr.quizAnswer.v1",
      producer: "human",
      content: { confirmed: true }
    });
    // First builder summary
    await waitUntil(() => workflows.getRun(run.id).events.some((event) =>
      event.type === "agent.started" &&
      (event.data as { nodeId?: string }).nodeId === "builder"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "round-summary",
      schema: "rlcr.summary.v1",
      producer: "builder",
      content: { stage: "ok" }
    });
    // Reviewer verdict says complete
    await waitUntil(() => workflows.getRun(run.id).events.some((event) =>
      event.type === "agent.started" &&
      (event.data as { nodeId?: string }).nodeId === "reviewer"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "review-verdict",
      schema: "rlcr.verdict.v1",
      producer: "reviewer",
      content: { status: "complete" }
    });
    await waitUntil(() => workflows.getRun(run.id).events.some((event) =>
      event.type === "agent.started" &&
      (event.data as { nodeId?: string }).nodeId === "code-review"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "code-review-result",
      schema: "rlcr.codeReview.v1",
      producer: "code-review",
      content: { status: "complete" }
    });
    // finalizer
    await waitUntil(() => workflows.getRun(run.id).events.some((event) =>
      event.type === "agent.started" &&
      (event.data as { nodeId?: string }).nodeId === "finalizer"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "rlcr-final",
      schema: "rlcr.final.v1",
      producer: "finalizer",
      content: { status: "complete" }
    });
    const finished = await workflows.waitForRun(run.id, 4_000);
    expect(finished.status).toBe("succeeded");
    const verticesCompleted = finished.events
      .filter((event) => event.type === "vertex.completed")
      .map((event) => (event.data as { vertexId?: string }).vertexId);
    expect(verticesCompleted).toContain("finalizer");
    expect(verticesCompleted).not.toContain("stopped");
  });

  it("code-review revise re-enters implementation before finalizing", async () => {
    const seenRequests: AgentRequest[] = [];
    const runCoordinator = new AgentRunCoordinator(new HumanizeService([
      slowBackend("codex", seenRequests, { initialDelayMs: 80, continuationDelayMs: 20 }),
      slowBackend("claude", seenRequests, { initialDelayMs: 80, continuationDelayMs: 20 })
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc"
    });
    const workflows = new WorkflowCoordinator(runCoordinator, {
      idFactory: ids([
        "workflow-run",
        "implementation-plan",
        "plan-compliance",
        "plan-quiz",
        "plan-quiz-answer",
        "round-summary",
        "review-verdict",
        "code-review-result",
        "round-summary-repair",
        "review-verdict-repair",
        "code-review-result-complete",
        "rlcr-final"
      ]),
      now: fixedClock()
    });
    const html = await readFlow("flow/rlcr/workflow.html");
    await workflows.loadHtml({
      html,
      sourcePath: "flow/rlcr/workflow.html"
    });

    const run = workflows.start({ cartridgeId: "rlcr" });
    const agentStartedCount = (nodeId: string) => workflows.getRun(run.id).events.filter((event) =>
      event.type === "agent.started" &&
      (event.data as { nodeId?: string }).nodeId === nodeId
    ).length;

    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "implementation-plan",
      schema: "rlcr.plan.v1",
      producer: "human",
      content: { steps: ["a"] }
    });
    await waitUntil(() => agentStartedCount("plan-compliance-checker") === 1);
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-compliance",
      schema: "rlcr.planCompliance.v1",
      producer: "plan-compliance-checker",
      content: { status: "pass" }
    });
    await waitUntil(() => agentStartedCount("plan-quiz-generator") === 1);
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-quiz",
      schema: "rlcr.quiz.v1",
      producer: "plan-quiz-generator",
      content: { questions: [] }
    });
    await waitUntil(() => workflows.getRun(run.id).waitingFor.some((target) =>
      target.kind === "human" && target.artifact === "plan-quiz-answer"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-quiz-answer",
      schema: "rlcr.quizAnswer.v1",
      producer: "human",
      content: { confirmed: true }
    });
    await waitUntil(() => agentStartedCount("builder") === 1);
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "round-summary",
      schema: "rlcr.summary.v1",
      producer: "builder",
      content: { status: "ready-for-review" }
    });
    await waitUntil(() => agentStartedCount("reviewer") === 1);
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "review-verdict",
      schema: "rlcr.verdict.v1",
      producer: "reviewer",
      content: { status: "complete" }
    });
    await waitUntil(() => agentStartedCount("code-review") === 1);
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "code-review-result",
      schema: "rlcr.codeReview.v1",
      producer: "code-review",
      content: { status: "revise", findings: ["Fix the review finding."] }
    });
    await waitUntil(() => agentStartedCount("builder") === 2);
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "round-summary",
      schema: "rlcr.summary.v1",
      producer: "builder",
      content: { status: "ready-for-review", repaired: true }
    });
    await waitUntil(() => agentStartedCount("reviewer") === 2);
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "review-verdict",
      schema: "rlcr.verdict.v1",
      producer: "reviewer",
      content: { status: "complete" }
    });
    await waitUntil(() => agentStartedCount("code-review") === 2);
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "code-review-result",
      schema: "rlcr.codeReview.v1",
      producer: "code-review",
      content: { status: "complete" }
    });
    await waitUntil(() => agentStartedCount("finalizer") === 1);
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "rlcr-final",
      schema: "rlcr.final.v1",
      producer: "finalizer",
      content: { status: "complete" }
    });

    const finished = await workflows.waitForRun(run.id, 4_000);
    expect(finished.status).toBe("succeeded");
    expect(finished.loopIterations["code-review-loop"]).toBe(2);
    expect(finished.loopIterations["implementation-loop"]).toBe(1);
    const reviewRoutes = finished.events.filter((event) =>
      event.type === "branch.routed" &&
      (event.data as { branchId?: string }).branchId === "code-review-route"
    );
    expect(reviewRoutes.map((event) => (event.data as { kind?: string }).kind)).toEqual([
      "continue-edge",
      "branch"
    ]);
  });

  it("stop route reaches the stop sink without executing finalizer", async () => {
    const seenRequests: AgentRequest[] = [];
    const runCoordinator = new AgentRunCoordinator(new HumanizeService([
      slowBackend("codex", seenRequests, { initialDelayMs: 80, continuationDelayMs: 20 }),
      slowBackend("claude", seenRequests, { initialDelayMs: 80, continuationDelayMs: 20 })
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc"
    });
    const workflows = new WorkflowCoordinator(runCoordinator, {
      idFactory: ids(["workflow-run", "implementation-plan", "plan-compliance", "plan-quiz", "plan-quiz-answer", "round-summary", "review-verdict"]),
      now: fixedClock()
    });
    const html = await readFlow("flow/rlcr/workflow.html");
    await workflows.loadHtml({ html, sourcePath: "flow/rlcr/workflow.html" });
    const run = workflows.start({ cartridgeId: "rlcr" });

    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "implementation-plan",
      schema: "rlcr.plan.v1",
      producer: "human",
      content: { steps: ["a"] }
    });
    await waitUntil(() => workflows.getRun(run.id).events.some((event) =>
      event.type === "agent.started" &&
      (event.data as { nodeId?: string }).nodeId === "plan-compliance-checker"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-compliance",
      schema: "rlcr.planCompliance.v1",
      producer: "plan-compliance-checker",
      content: { status: "pass" }
    });
    await waitUntil(() => workflows.getRun(run.id).events.some((event) =>
      event.type === "agent.started" &&
      (event.data as { nodeId?: string }).nodeId === "plan-quiz-generator"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-quiz",
      schema: "rlcr.quiz.v1",
      producer: "plan-quiz-generator",
      content: { questions: [] }
    });
    await waitUntil(() => workflows.getRun(run.id).waitingFor.some((target) =>
      target.kind === "human" && target.artifact === "plan-quiz-answer"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-quiz-answer",
      schema: "rlcr.quizAnswer.v1",
      producer: "human",
      content: { confirmed: true }
    });
    await waitUntil(() => workflows.getRun(run.id).events.some((event) =>
      event.type === "agent.started" &&
      (event.data as { nodeId?: string }).nodeId === "builder"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "round-summary",
      schema: "rlcr.summary.v1",
      producer: "builder",
      content: { stage: "ok" }
    });
    await waitUntil(() => workflows.getRun(run.id).events.some((event) =>
      event.type === "agent.started" &&
      (event.data as { nodeId?: string }).nodeId === "reviewer"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "review-verdict",
      schema: "rlcr.verdict.v1",
      producer: "reviewer",
      content: { status: "stop" }
    });
    const finished = await workflows.waitForRun(run.id, 4_000);
    expect(finished.status).toBe("succeeded");
    const verticesCompleted = finished.events
      .filter((event) => event.type === "vertex.completed")
      .map((event) => (event.data as { vertexId?: string }).vertexId);
    expect(verticesCompleted).toContain("stopped");
    expect(verticesCompleted).not.toContain("finalizer");
  });
});

async function readFlow(path: string): Promise<string> {
  const { readFile } = await import("node:fs/promises");
  return readFile(path, "utf8");
}

async function makeTempDir(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "humanize2-gap-coverage-"));
  tempDirs.push(dir);
  return dir;
}

function newCoordinator(): WorkflowCoordinator {
  return new WorkflowCoordinator(emptyRunCoordinator(), {
    idFactory: ids(["workflow-run"]),
    now: fixedClock()
  });
}

function emptyRunCoordinator(): AgentRunCoordinator {
  return new AgentRunCoordinator(new HumanizeService([
    fakeBackend("codex"),
    fakeBackend("claude")
  ]), {
    jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc"
  });
}

function slowRunCoordinator(): AgentRunCoordinator {
  return new AgentRunCoordinator(new HumanizeService([
    slowBackend("codex", [], { initialDelayMs: 80, continuationDelayMs: 10 }),
    slowBackend("claude", [], { initialDelayMs: 80, continuationDelayMs: 10 })
  ]), {
    jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc"
  });
}

function fakeBackend(id: AgentId): AgentBackend {
  return {
    id,
    displayName: `${id} backend`,
    async status(): Promise<AgentStatus> {
      return { agent: id, displayName: `${id} backend`, available: true };
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

interface SlowOptions {
  initialDelayMs: number;
  continuationDelayMs: number;
}

function slowBackend(id: AgentId, seenRequests: AgentRequest[], options: SlowOptions): AgentBackend {
  return {
    id,
    displayName: `${id} slow`,
    async status(): Promise<AgentStatus> {
      return { agent: id, displayName: `${id} slow`, available: true };
    },
    async run(request: AgentRequest): Promise<AgentResult> {
      seenRequests.push(request);
      const isContinuation = request.resumeSessionId !== undefined;
      const delay = isContinuation ? options.continuationDelayMs : options.initialDelayMs;
      const backendSessionId = request.resumeSessionId ?? `${id}-${seenRequests.length}`;
      request.onOutput?.({ stream: "stdout", text: `{"type":"thread.started","session_id":"${backendSessionId}"}\n` });
      await new Promise<void>((resolve) => {
        const timeout = setTimeout(resolve, delay);
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
        durationMs: delay,
        timedOut: false,
        command: id,
        args: [request.prompt],
        cwd: request.cwd,
        backendSessionId
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
  return () => new Date(Date.UTC(2026, 4, 14, 23, 0, index++)).toISOString();
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt > 3_000) {
      throw new Error("timed out waiting for test condition");
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
