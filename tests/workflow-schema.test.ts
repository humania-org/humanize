import { describe, expect, it } from "vitest";
import { z } from "zod";

import type { AgentBackend, AgentId, AgentRequest, AgentResult, AgentStatus } from "../src/agents/types.js";
import { AgentRunCoordinator } from "../src/hub/runs.js";
import { HumanizeService } from "../src/service.js";
import { WorkflowCoordinator } from "../src/workflows/coordinator.js";
import { createDefaultSchemaRegistry, createSchemaRegistry } from "../src/workflows/schema-registry.js";

describe("workflow artifact schema registry (v0.1)", () => {
  it("validates control-flow schemas in the default registry instead of accepting arbitrary content", () => {
    const registry = createDefaultSchemaRegistry();

    expect(registry.validate("route.v1", { next: "review" })).toEqual({ status: "accepted" });
    expect(registry.validate("route.v1", { wrong: "review" }).status).toBe("schema-mismatch");
    expect(registry.validate("rlcr.verdict.v1", { status: "complete" })).toEqual({ status: "accepted" });
    expect(registry.validate("rlcr.verdict.v1", { status: "banana" }).status).toBe("schema-mismatch");
  });

  it("accepts a registered schema when content matches and lets the agent expectation complete", async () => {
    const registry = createSchemaRegistry();
    registry.register("result.v1", z.object({ status: z.enum(["ok", "fail"]) }));

    const seenRequests: AgentRequest[] = [];
    const runCoordinator = new AgentRunCoordinator(new HumanizeService([
      slowBackend("codex", seenRequests),
      slowBackend("claude", seenRequests)
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc",
      idFactory: ids(["builder-run"])
    });
    const workflows = new WorkflowCoordinator(runCoordinator, {
      idFactory: ids(["workflow-run", "artifact-1"]),
      now: fixedClock(),
      schemaRegistry: registry
    });

    await workflows.loadHtml({
      html: schemaFlowHtml(["result.v1"])
    });
    const run = workflows.start({ cartridgeId: "schema-flow" });
    await waitUntil(() => seenRequests.length >= 1);

    const artifact = workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "result",
      schema: "result.v1",
      producer: "builder",
      content: { status: "ok" }
    });

    expect(artifact.validationStatus).toBe("accepted");
    const finished = await workflows.waitForRun(run.id, 2_000);
    expect(finished.status).toBe("succeeded");
    expect(finished.events.some((event) => event.type === "artifact.schema_mismatch")).toBe(false);
    const expectationSatisfied = finished.events.find((event) => event.type === "agent.expectation_satisfied");
    expect(expectationSatisfied).toBeDefined();
  });

  it("flags schema-mismatch and does not satisfy the agent expectation when content fails the registered validator", async () => {
    const registry = createSchemaRegistry();
    registry.register("result.v1", z.object({ status: z.enum(["ok", "fail"]) }));

    const seenRequests: AgentRequest[] = [];
    const runCoordinator = new AgentRunCoordinator(new HumanizeService([
      slowBackend("codex", seenRequests),
      slowBackend("claude", seenRequests)
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc",
      idFactory: ids(["builder-run", "builder-retry-1", "builder-retry-2", "builder-retry-3"])
    });
    const workflows = new WorkflowCoordinator(runCoordinator, {
      idFactory: ids(["workflow-run", "artifact-1"]),
      now: fixedClock(),
      schemaRegistry: registry,
      softEnforcementRetryMax: 1
    });

    await workflows.loadHtml({ html: schemaFlowHtml(["result.v1"]) });
    const run = workflows.start({ cartridgeId: "schema-flow" });
    await waitUntil(() => seenRequests.length >= 1);

    const artifact = workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "result",
      schema: "result.v1",
      producer: "builder",
      content: { status: "weird" }
    });

    expect(artifact.validationStatus).toBe("schema-mismatch");
    const finished = await workflows.waitForRun(run.id, 2_000);
    expect(finished.status).toBe("failed");
    const mismatchEvent = finished.events.find((event) => event.type === "artifact.schema_mismatch");
    expect(mismatchEvent).toBeDefined();
    const retryEvent = finished.events.find((event) => event.type === "agent.expectation_retry");
    expect(retryEvent).toBeDefined();
    const retryData = retryEvent?.data as { missing?: string[] };
    expect(retryData?.missing).toEqual(["result"]);
    // The continuation message should mention the schema name.
    const sentMessages = seenRequests.map((request) => request.prompt);
    expect(sentMessages.some((message) => message.includes("result.v1"))).toBe(true);
  });

  it("treats unregistered schemas as opaque and emits manifest-undeclared status", async () => {
    const registry = createSchemaRegistry();
    // Intentionally do NOT register `unregistered.v9`.

    const workflows = new WorkflowCoordinator(emptyRunCoordinator(), {
      idFactory: ids(["workflow-run", "artifact-1"]),
      now: fixedClock(),
      schemaRegistry: registry
    });

    await workflows.loadHtml({
      html: `
        <h2-workflow id="opaque-flow" name="Opaque Flow" version="0.1.0">
          <h2-manifest>
            <h2-capability name="artifact" schemas="result.v1,unregistered.v9"></h2-capability>
          </h2-manifest>
          <h2-flow></h2-flow>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: "opaque-flow" });

    const artifact = workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "opaque-thing",
      schema: "unregistered.v9",
      producer: "external",
      content: { arbitrary: "shape" }
    });
    expect(artifact.validationStatus).toBe("manifest-undeclared");
  });
});

function schemaFlowHtml(declaredSchemas: string[]): string {
  return `
    <h2-workflow id="schema-flow" name="Schema Flow" version="0.1.0">
      <h2-manifest>
        <h2-capability name="agent" tools="codex"></h2-capability>
        <h2-capability name="artifact" schemas="${declaredSchemas.join(",")}"></h2-capability>
      </h2-manifest>
      <h2-template id="builder-prompt">Builder: deliver result.</h2-template>
      <h2-flow>
        <h2-agent id="builder" tool="codex" prompt="#builder-prompt" short-name="builder">
          <h2-expect artifact="result" schema="result.v1"></h2-expect>
        </h2-agent>
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
        const timeout = setTimeout(resolve, 10);
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
    if (Date.now() - startedAt > 2_000) {
      throw new Error("timed out waiting for test condition");
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
