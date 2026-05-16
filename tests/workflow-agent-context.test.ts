import { describe, expect, it } from "vitest";

import type { AgentBackend, AgentId, AgentRequest, AgentResult, AgentStatus } from "../src/agents/types.js";
import { AgentRunCoordinator } from "../src/hub/runs.js";
import { HumanizeService } from "../src/service.js";
import { WorkflowCoordinator } from "../src/workflows/coordinator.js";

const EXPECTED_MCP_TOOLS = [
  "agent_spawn_child",
  "agent_send_message",
  "agent_wait",
  "artifact_deliver",
  "board_patch",
  "board_get",
  "artifact_get",
  "event_emit",
  "view_publish",
  "human_request",
  "human_answer"
];

describe("workflow-spawned agents receive a workflow launch context", () => {
  it("populates workflowContext on the AgentRequest the backend observes", async () => {
    const seenRequests: AgentRequest[] = [];
    const jsonRpcUrl = "http://127.0.0.1:4773/jsonrpc";
    const runCoordinator = new AgentRunCoordinator(new HumanizeService([
      capturingBackend("codex", seenRequests),
      capturingBackend("claude", seenRequests)
    ]), {
      jsonRpcUrl,
      idFactory: ids(["builder-run"])
    });
    const workflows = new WorkflowCoordinator(runCoordinator, {
      idFactory: ids(["workflow-run", "artifact-1"]),
      now: fixedClock()
    });

    await workflows.loadHtml({
      html: `
        <h2-workflow id="ctx-flow" name="Context Flow" version="0.1.0">
          <h2-manifest>
            <h2-capability name="agent" tools="codex"></h2-capability>
            <h2-capability name="artifact" schemas="result.v1"></h2-capability>
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
    const run = workflows.start({ cartridgeId: "ctx-flow" });
    await waitUntil(() => seenRequests.length >= 1);

    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "result",
      schema: "result.v1",
      producer: "builder",
      content: { status: "ok" }
    });
    const finished = await workflows.waitForRun(run.id, 2_000);
    expect(finished.status).toBe("succeeded");

    expect(seenRequests).toHaveLength(1);
    const request = seenRequests[0];
    expect(request.workflowContext).toBeDefined();
    const context = request.workflowContext!;
    expect(context.workflowRunId).toBe(run.id);
    expect(context.vertexId).toBe("builder");
    expect(context.shortName).toBe("builder");
    expect(context.jsonRpcUrl).toBe(jsonRpcUrl);
    expect(context.expectedArtifacts).toEqual([
      { name: "result", schema: "result.v1" }
    ]);
    expect(context.mcpToolNames).toEqual(expect.arrayContaining(EXPECTED_MCP_TOOLS));
    // Sanity: the cwd plumbed through to backend should still be unset (no h2-agent cwd).
    expect(request.cwd).toBeUndefined();
  });

  it("passes workflow start cwd to workflow-spawned agent requests", async () => {
    const seenRequests: AgentRequest[] = [];
    const runCoordinator = new AgentRunCoordinator(new HumanizeService([
      capturingBackend("codex", seenRequests),
      capturingBackend("claude", seenRequests)
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4773/jsonrpc",
      idFactory: ids(["builder-run"])
    });
    const workflows = new WorkflowCoordinator(runCoordinator, {
      idFactory: ids(["workflow-run"]),
      now: fixedClock()
    });

    await workflows.loadHtml({
      html: `
        <h2-workflow id="cwd-flow" name="Cwd Flow" version="0.1.0">
          <h2-manifest><h2-capability name="agent" tools="codex"></h2-capability></h2-manifest>
          <h2-template id="builder-prompt">Builder: do work.</h2-template>
          <h2-flow>
            <h2-agent id="builder" tool="codex" prompt="#builder-prompt" short-name="builder"></h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    });
    workflows.start({ cartridgeId: "cwd-flow", cwd: "/tmp/humanize2-workflow-project" } as any);
    await waitUntil(() => seenRequests.length >= 1);

    expect(seenRequests[0].cwd).toBe("/tmp/humanize2-workflow-project");
  });

  it("injects declared artifact and board inputs into workflow agent context", async () => {
    const seenRequests: AgentRequest[] = [];
    const runCoordinator = new AgentRunCoordinator(new HumanizeService([
      capturingBackend("codex", seenRequests),
      capturingBackend("claude", seenRequests)
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4773/jsonrpc",
      idFactory: ids(["builder-run"])
    });
    const workflows = new WorkflowCoordinator(runCoordinator, {
      idFactory: ids(["workflow-run", "verdict-artifact", "result-artifact"]),
      now: fixedClock()
    });

    await workflows.loadHtml({
      html: `
        <h2-workflow id="input-flow" name="Input Flow" version="0.1.0">
          <h2-manifest>
            <h2-capability name="agent" tools="codex"></h2-capability>
            <h2-capability name="artifact" schemas="rlcr.verdict.v1,result.v1"></h2-capability>
          </h2-manifest>
          <h2-state>
            <h2-board id="loop-status" schema="status.v1"></h2-board>
          </h2-state>
          <h2-template id="builder-prompt">Builder: address review.</h2-template>
          <h2-flow>
            <h2-await id="wait-for-review" on="exists(artifact.review-verdict)"></h2-await>
            <h2-agent id="builder" tool="codex" prompt="#builder-prompt" short-name="builder">
              <h2-input artifact="review-verdict" schema="rlcr.verdict.v1" label="Latest review"></h2-input>
              <h2-input board="loop-status" label="Loop status"></h2-input>
              <h2-expect artifact="result" schema="result.v1"></h2-expect>
            </h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: "input-flow" });
    workflows.patchBoard({
      workflowRunId: run.id,
      boardId: "loop-status",
      patch: { status: "revise", requiredFollowUp: ["Fix H2WF001"] }
    });
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "review-verdict",
      schema: "rlcr.verdict.v1",
      producer: "reviewer",
      content: { status: "revise", requiredFollowUp: ["Fix H2WF001"] }
    });
    await waitUntil(() => seenRequests.length >= 1);

    const inputs = (seenRequests[0].workflowContext as any).inputs;
    expect(inputs).toMatchObject([
      {
        kind: "artifact",
        name: "review-verdict",
        schema: "rlcr.verdict.v1",
        label: "Latest review",
        content: { status: "revise", requiredFollowUp: ["Fix H2WF001"] }
      },
      {
        kind: "board",
        id: "loop-status",
        label: "Loop status",
        value: { status: "revise", requiredFollowUp: ["Fix H2WF001"] }
      }
    ]);
  });

  it("preserves workflow context when a managed message continues a workflow run", async () => {
    const seenRequests: AgentRequest[] = [];
    const runCoordinator = new AgentRunCoordinator(new HumanizeService([
      capturingBackend("codex", seenRequests),
      capturingBackend("claude", seenRequests)
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4773/jsonrpc",
      idFactory: ids(["initial-run", "continuation-run"])
    });
    const context = {
      workflowRunId: "workflow-run",
      vertexId: "builder",
      shortName: "builder",
      jsonRpcUrl: "http://127.0.0.1:4773/jsonrpc",
      expectedArtifacts: [{ name: "result", schema: "result.v1" }],
      mcpToolNames: EXPECTED_MCP_TOOLS
    };

    const initial = runCoordinator.createRun({
      agent: "codex",
      prompt: "initial task",
      timeoutMs: 5_000,
      workflowContext: context
    });
    await waitUntil(() => seenRequests.length >= 1);
    const continuation = await runCoordinator.sendMessage({
      runId: initial.id,
      message: "changed task",
      timeoutMs: 5_000
    });
    await runCoordinator.waitForRun(continuation.id, 2_000);

    expect(seenRequests).toHaveLength(2);
    expect(seenRequests[1].workflowContext).toEqual(context);
  });
});

function capturingBackend(id: AgentId, seenRequests: AgentRequest[]): AgentBackend {
  return {
    id,
    displayName: `${id} capturing backend`,
    async status(): Promise<AgentStatus> {
      return {
        agent: id,
        displayName: `${id} capturing backend`,
        available: true,
        version: `${id}-test`
      };
    },
    async run(request: AgentRequest): Promise<AgentResult> {
      seenRequests.push(request);
      const backendSessionId = request.resumeSessionId ?? `${id}-${seenRequests.length}`;
      request.onOutput?.({ stream: "stdout", text: `{"type":"thread.started","session_id":"${backendSessionId}"}\n` });
      await new Promise<void>((resolve) => {
        const timeout = setTimeout(resolve, 5);
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
    if (Date.now() - startedAt > 2_000) {
      throw new Error("timed out waiting for test condition");
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
