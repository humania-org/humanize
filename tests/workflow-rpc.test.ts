import type { Server } from "node:http";

import { afterEach, describe, expect, it } from "vitest";

import type { AgentBackend, AgentId, AgentRequest, AgentResult, AgentStatus } from "../src/agents/types.js";
import { callHubRpc } from "../src/hub-client.js";
import { createHubHttpServer } from "../src/hub/http-server.js";
import { AgentRunCoordinator } from "../src/hub/runs.js";
import { HumanizeService } from "../src/service.js";
import { WorkflowCoordinator } from "../src/workflows/coordinator.js";

const openServers: Server[] = [];

afterEach(async () => {
  await Promise.all(openServers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve()))));
});

describe("workflow JSON-RPC surface", () => {
  it("loads, starts, inspects, and completes an HTML workflow with artifacts", async () => {
    const workflows = new WorkflowCoordinator(testRunCoordinator(), {
      idFactory: ids(["workflow-run", "artifact-done"]),
      now: fixedClock()
    });
    const server = createHubHttpServer(testRunCoordinator(), { workflowCoordinator: workflows });
    openServers.push(server);
    const url = await listen(server);

    const info = await callHubRpc({ url: `${url}/jsonrpc`, method: "system.info", params: {} }) as { methods: string[] };
    expect(info.methods).toContain("workflow.load_html");
    expect(info.methods).toContain("artifact.deliver");

    const load = await callHubRpc({
      url: `${url}/jsonrpc`,
      method: "workflow.load_html",
      params: {
        html: `
          <h2-workflow id="artifact-flow" name="Artifact Flow" version="0.1.0">
            <h2-flow>
              <h2-await id="done-wait" on="exists(artifact.done)"></h2-await>
            </h2-flow>
          </h2-workflow>
        `
      }
    }) as { cartridgeId: string };
    expect(load).toEqual({ cartridgeId: "artifact-flow" });

    const start = await callHubRpc({
      url: `${url}/jsonrpc`,
      method: "workflow.start",
      params: { cartridgeId: "artifact-flow" }
    }) as { workflowRunId: string };
    expect(start).toEqual({ workflowRunId: "workflow-run" });

    await new Promise((resolve) => setTimeout(resolve, 20));

    const waiting = await callHubRpc({
      url: `${url}/jsonrpc`,
      method: "workflow.get",
      params: { workflowRunId: "workflow-run" }
    }) as { status: string; waitingFor: Array<{ kind: string; expression?: string }> };
    expect(waiting.status).toBe("waiting");
    expect(waiting.waitingFor.some((target) => target.kind === "predicate" && (target.expression ?? "").includes("done"))).toBe(true);

    const artifact = await callHubRpc({
      url: `${url}/jsonrpc`,
      method: "artifact.deliver",
      params: {
        workflowRunId: "workflow-run",
        name: "done",
        schema: "done.v1",
        producer: "test",
        content: { ok: true }
      }
    }) as { artifactId: string };
    expect(artifact).toEqual({ artifactId: "artifact-done" });

    const finished = await callHubRpc({
      url: `${url}/jsonrpc`,
      method: "workflow.wait",
      params: { workflowRunId: "workflow-run", timeoutMs: 1_000 }
    }) as { status: string; artifacts: Array<{ name: string; content: unknown }> };
    expect(finished.status).toBe("succeeded");
    expect(finished.artifacts).toMatchObject([{ name: "done", content: { ok: true } }]);
  });
});

function testRunCoordinator(): AgentRunCoordinator {
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
        available: true,
        version: `${id}-test`
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

async function listen(server: Server): Promise<string> {
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
  const address = server.address();
  if (address === null || typeof address === "string") {
    throw new Error("missing server address");
  }
  return `http://127.0.0.1:${address.port}`;
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
  return () => new Date(Date.UTC(2026, 4, 14, 19, 0, index++)).toISOString();
}
