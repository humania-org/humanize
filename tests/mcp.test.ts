import type { Server } from "node:http";

import { afterEach, describe, expect, it } from "vitest";

import type { AgentBackend, AgentId, AgentRequest, AgentResult, AgentStatus } from "../src/agents/types.js";
import { callHumanizeTool, listHumanizeTools, type ToolCallResult } from "../src/dev-client.js";
import { createHubHttpServer } from "../src/hub/http-server.js";
import { AgentRunCoordinator } from "../src/hub/runs.js";
import { HumanizeService } from "../src/service.js";
import { WorkflowCoordinator } from "../src/workflows/coordinator.js";

const tsxCli = new URL("../node_modules/tsx/dist/cli.mjs", import.meta.url).pathname;
const openServers: Server[] = [];

function serverOptions() {
  return {
    command: process.execPath,
    args: [tsxCli, "src/index.ts"],
    cwd: new URL("..", import.meta.url).pathname,
    env: {
      ...process.env,
      HUMANIZE2_FAKE_AGENT_RESPONSE: "fake-ok"
    }
  };
}

describe("humanize2 MCP stdio surface", () => {
  afterEach(async () => {
    await Promise.all(openServers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve()))));
  });

  it("lists the agent gateway tools and derives the workflow tool set from JSON-RPC parity", async () => {
    const result = await listHumanizeTools(serverOptions());
    const coordinator = testCoordinator([], ["unused"]);
    const workflows = new WorkflowCoordinator(coordinator, { idFactory: ids(["unused-workflow"]) });
    const server = createHubHttpServer(coordinator, { workflowCoordinator: workflows });
    openServers.push(server);
    const url = await listen(server);

    const info = await fetch(`${url}/jsonrpc`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "system.info" })
    });
    const infoPayload = (await info.json()) as { result?: { methods?: string[] } };
    const methods = infoPayload.result?.methods ?? [];
    const workflowMethodSet = methods.filter((method) =>
      method.startsWith("workflow.") || method.startsWith("artifact.") || method.startsWith("board.") ||
      method.startsWith("human.") || method.startsWith("event.") || method.startsWith("view.")
    );
    const expectedWorkflowToolNames = workflowMethodSet.map((method) => method.replace(/\./g, "_"));

    const baselineTools = [
      "agent_run",
      "agent_send_message",
      "agent_spawn_child",
      "agent_status",
      "agent_wait",
      "claude_run",
      "codex_run"
    ];

    const actualTools = result.tools.map((tool) => tool.name).sort();
    const expectedSet = new Set([...baselineTools, ...expectedWorkflowToolNames]);
    for (const tool of expectedSet) {
      expect(actualTools).toContain(tool);
    }
    // Every workflow-shaped JSON-RPC method must be reachable via MCP under the dot-to-underscore rule.
    expect(workflowMethodSet).toContain("workflow.list");
    expect(actualTools).toContain("workflow_list");
    for (const method of workflowMethodSet) {
      expect(actualTools).toContain(method.replace(/\./g, "_"));
    }
  });

  it("calls agent_run through the local JSON-RPC harness", async () => {
    const result = await callHumanizeTool({
      ...serverOptions(),
      toolName: "agent_run",
      arguments: {
        agent: "codex",
        prompt: "Say hello"
      }
    });

    const textBlock = result.content.find(
      (block): block is { type: "text"; text: string } => block.type === "text"
    );
    const text = textBlock?.text;
    expect(text).toBeDefined();

    const payload = JSON.parse(text ?? "{}");
    expect(payload.agent).toBe("codex");
    expect(payload.success).toBe(true);
    expect(payload.stdout).toBe("fake-ok");
  });

  it("allows long-running tool calls by configuring the JSON-RPC timeout", async () => {
    const startedAt = Date.now();
    const result = await callHumanizeTool({
      ...serverOptions(),
      env: {
        ...process.env,
        HUMANIZE2_FAKE_AGENT_RESPONSE: "delayed-ok",
        HUMANIZE2_FAKE_AGENT_DELAY_MS: "600"
      },
      rpcTimeoutMs: 2_000,
      toolName: "agent_run",
      arguments: {
        agent: "codex",
        prompt: "Wait briefly"
      }
    });

    const textBlock = result.content.find(
      (block): block is { type: "text"; text: string } => block.type === "text"
    );
    const payload = JSON.parse(textBlock?.text ?? "{}");

    expect(Date.now() - startedAt).toBeGreaterThanOrEqual(500);
    expect(payload.stdout).toBe("delayed-ok");
  });

  it("spawns and waits for a child run through the hub tools", async () => {
    const seenRequests: AgentRequest[] = [];
    const coordinator = testCoordinator(seenRequests, ["parent-run", "child-run", "child-message"]);
    const parent = coordinator.createRun({
      agent: "codex",
      prompt: "parent task",
      cwd: "/tmp/project"
    });
    await coordinator.waitForRun(parent.id, 1_000);
    const server = createHubHttpServer(coordinator);
    openServers.push(server);
    const url = await listen(server);

    const spawnResult = await callHumanizeTool({
      ...serverOptions(),
      env: {
        ...process.env,
        HUMANIZE2_FAKE_AGENT_RESPONSE: "fake-ok",
        HUMANIZE2_JSONRPC_URL: `${url}/jsonrpc`,
        HUMANIZE2_RUN_ID: parent.id
      },
      toolName: "agent_spawn_child",
      arguments: {
        agent: "claude",
        prompt: "child task",
        cwd: "/tmp/project"
      }
    });
    const spawnPayload = JSON.parse(textContent(spawnResult));
    expect(spawnPayload).toEqual({ runId: "child-run" });

    const waitResult = await callHumanizeTool({
      ...serverOptions(),
      env: {
        ...process.env,
        HUMANIZE2_FAKE_AGENT_RESPONSE: "fake-ok",
        HUMANIZE2_JSONRPC_URL: `${url}/jsonrpc`
      },
      toolName: "agent_wait",
      arguments: {
        runId: "child-run",
        timeoutMs: 1_000
      }
    });
    const waitPayload = JSON.parse(textContent(waitResult));

    expect(waitPayload).toMatchObject({
      id: "child-run",
      parentRunId: "parent-run",
      agent: "claude",
      status: "succeeded"
    });

    const messageResult = await callHumanizeTool({
      ...serverOptions(),
      env: {
        ...process.env,
        HUMANIZE2_FAKE_AGENT_RESPONSE: "fake-ok",
        HUMANIZE2_JSONRPC_URL: `${url}/jsonrpc`,
        HUMANIZE2_RUN_ID: parent.id,
        HUMANIZE2_RUN_SHORT_NAME: "parent"
      },
      toolName: "agent_send_message",
      arguments: {
        runId: "child-run",
        message: "change child task",
        shortName: "child-change"
      }
    });
    expect(JSON.parse(textContent(messageResult))).toEqual({ runId: "child-message" });
    const continued = await coordinator.waitForRun("child-message", 1_000);

    expect(continued.messageOrigin).toEqual({
      kind: "agent",
      sender: "parent",
      sourceRunId: "parent-run"
    });
    expect(seenRequests.map((request) => request.prompt)).toEqual(["parent task", "child task", "change child task"]);
  });

  it("loads, starts, and completes a workflow through MCP tools", async () => {
    const coordinator = testCoordinator([], ["unused"]);
    const workflows = new WorkflowCoordinator(coordinator, {
      idFactory: ids(["workflow-run", "artifact-done"])
    });
    const server = createHubHttpServer(coordinator, { workflowCoordinator: workflows });
    openServers.push(server);
    const url = await listen(server);
    const env = {
      ...process.env,
      HUMANIZE2_JSONRPC_URL: `${url}/jsonrpc`
    };

    const loadResult = await callHumanizeTool({
      ...serverOptions(),
      env,
      toolName: "workflow_load_html",
      arguments: {
        html: `
          <h2-workflow id="mcp-flow" name="MCP Flow" version="0.1.0">
            <h2-flow><h2-await id="done-wait" on="exists(artifact.done)"></h2-await></h2-flow>
          </h2-workflow>
        `
      }
    });
    expect(JSON.parse(textContent(loadResult))).toEqual({ cartridgeId: "mcp-flow" });

    const startResult = await callHumanizeTool({
      ...serverOptions(),
      env,
      toolName: "workflow_start",
      arguments: { cartridgeId: "mcp-flow" }
    });
    expect(JSON.parse(textContent(startResult))).toEqual({ workflowRunId: "workflow-run" });

    const artifactResult = await callHumanizeTool({
      ...serverOptions(),
      env,
      toolName: "artifact_deliver",
      arguments: {
        workflowRunId: "workflow-run",
        name: "done",
        schema: "done.v1",
        producer: "test",
        content: { ok: true }
      }
    });
    expect(JSON.parse(textContent(artifactResult))).toEqual({ artifactId: "artifact-done" });

    const waitResult = await callHumanizeTool({
      ...serverOptions(),
      env,
      toolName: "workflow_wait",
      arguments: {
        workflowRunId: "workflow-run",
        timeoutMs: 1_000
      }
    });
    expect(JSON.parse(textContent(waitResult))).toMatchObject({
      id: "workflow-run",
      status: "succeeded",
      artifacts: [{ name: "done", content: { ok: true } }]
    });
  });
});

function textContent(result: ToolCallResult): string {
  const textBlock = result.content.find(
    (block): block is { type: "text"; text: string } => "type" in block && block.type === "text"
  );
  return textBlock?.text ?? "{}";
}

function testCoordinator(seenRequests: AgentRequest[], ids: string[]): AgentRunCoordinator {
  const service = new HumanizeService([
    fakeBackend("codex", seenRequests),
    fakeBackend("claude", seenRequests)
  ]);

  return new AgentRunCoordinator(service, {
    jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc",
    idFactory: () => {
      const next = ids.shift();
      if (next === undefined) {
        throw new Error("missing test id");
      }
      return next;
    }
  });
}

function fakeBackend(id: AgentId, seenRequests: AgentRequest[]): AgentBackend {
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
      seenRequests.push(request);
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
