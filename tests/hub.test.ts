import type { Server } from "node:http";
import { readFileSync } from "node:fs";
import vm from "node:vm";

import { afterEach, describe, expect, it } from "vitest";

import type { AgentBackend, AgentId, AgentRequest, AgentResult, AgentStatus } from "../src/agents/types.js";
import { createHubHttpServer } from "../src/hub/http-server.js";
import { AgentRunCoordinator } from "../src/hub/runs.js";
import { HumanizeService } from "../src/service.js";
import { WorkflowCoordinator } from "../src/workflows/coordinator.js";

const openServers: Server[] = [];
const packageVersion = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version as string;

afterEach(async () => {
  await Promise.all(openServers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve()))));
});

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
      request.onOutput?.({ stream: "stdout", text: `out:${request.prompt}` });
      request.onOutput?.({ stream: "stderr", text: `err:${request.prompt}` });
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

function interruptibleBackend(
  id: AgentId,
  seenRequests: AgentRequest[],
  options: { abortDelayMs?: number; continuationDelayMs?: number } = {}
): AgentBackend {
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
      request.onOutput?.({ stream: "stdout", text: '{"type":"thread.started","session_id":"agent-session-a"}\n' });

      if (request.prompt === "original direction") {
        await new Promise<void>((resolve) => {
          request.signal?.addEventListener("abort", () => {
            setTimeout(resolve, options.abortDelayMs ?? 0);
          }, { once: true });
        });
        request.onOutput?.({ stream: "stderr", text: "backend noticed abort\n" });
        return {
          agent: id,
          success: false,
          exitCode: null,
          signal: "SIGTERM",
          stdout: "",
          stderr: "aborted",
          durationMs: 10,
          timedOut: false,
          command: id,
          args: [request.prompt],
          cwd: request.cwd,
          backendSessionId: "agent-session-a"
        };
      }

      if (options.continuationDelayMs !== undefined) {
        await new Promise((resolve) => setTimeout(resolve, options.continuationDelayMs));
      }
      request.onOutput?.({ stream: "stdout", text: `continued:${request.prompt}` });
      return {
        agent: id,
        success: true,
        exitCode: 0,
        signal: null,
        stdout: `continued:${request.prompt}`,
        stderr: "",
        durationMs: 1,
        timedOut: false,
        command: id,
        args: [request.prompt],
        cwd: request.cwd,
        backendSessionId: request.resumeSessionId
      };
    }
  };
}

function coordinator(seenRequests: AgentRequest[], ids: string[]): AgentRunCoordinator {
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

function interruptibleCoordinator(
  seenRequests: AgentRequest[],
  ids: string[],
  options: { abortDelayMs?: number; continuationDelayMs?: number } = {}
): AgentRunCoordinator {
  const service = new HumanizeService([
    interruptibleBackend("codex", seenRequests, options),
    interruptibleBackend("claude", seenRequests, options)
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

async function waitUntil(predicate: () => boolean): Promise<void> {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt > 1_000) {
      throw new Error("timed out waiting for test condition");
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

describe("AgentRunCoordinator", () => {
  it("applies configured agent model defaults to created runs and backend requests", async () => {
    const seenRequests: AgentRequest[] = [];
    const runs = new AgentRunCoordinator(new HumanizeService([
      fakeBackend("codex", seenRequests),
      fakeBackend("claude", seenRequests)
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc",
      idFactory: ids(["run-a", "run-b"]),
      agentDefaults: {
        claude: {
          model: "claude-sonnet-4-6",
          reasoningEffort: "high"
        }
      }
    });

    const defaulted = runs.createRun({ agent: "claude", prompt: "use default model" });
    await runs.waitForRun(defaulted.id, 1_000);
    const explicit = runs.createRun({
      agent: "claude",
      prompt: "use explicit model",
      model: "claude-opus-4-7",
      reasoningEffort: "xhigh"
    });
    await runs.waitForRun(explicit.id, 1_000);

    expect(runs.getRun(defaulted.id)).toMatchObject({
      model: "claude-sonnet-4-6",
      reasoningEffort: "high"
    });
    expect(seenRequests[0]).toMatchObject({
      model: "claude-sonnet-4-6",
      reasoningEffort: "high"
    });
    expect(seenRequests[1]).toMatchObject({
      model: "claude-opus-4-7",
      reasoningEffort: "xhigh"
    });
  });

  it("centrally records logical parent-child runs and injects hub environment", async () => {
    const seenRequests: AgentRequest[] = [];
    const runs = coordinator(seenRequests, ["run-parent", "run-child"]);

    const parent = runs.createRun({ agent: "codex", prompt: "parent task", cwd: "/tmp/project", shortName: "parent price check" });
    await runs.waitForRun(parent.id, 1_000);

    const child = runs.createRun(
      { agent: "claude", prompt: "child task", cwd: "/tmp/project", timeoutMs: 123_000 },
      { parentRunId: parent.id }
    );
    const childRecord = await runs.waitForRun(child.id, 1_000);

    expect(childRecord.parentRunId).toBe(parent.id);
    expect(parent.shortName).toBe("parent price check");
    expect(childRecord.shortName).toBe("child task");
    expect(childRecord.timeoutMs).toBe(123_000);
    expect(childRecord.project).toMatchObject({
      path: "/tmp/project",
      git: {
        isRepo: false
      }
    });
    expect(childRecord.outputEvents).toMatchObject([
      {
        stream: "stdout",
        text: "out:child task"
      },
      {
        stream: "stderr",
        text: "err:child task"
      }
    ]);
    expect(runs.listRuns().map((run) => run.id)).toEqual(["run-parent", "run-child"]);
    expect(seenRequests[0].env).toMatchObject({
      HUMANIZE2_JSONRPC_URL: "http://127.0.0.1:4772/jsonrpc",
      HUMANIZE2_RUN_ID: "run-parent"
    });
    expect(seenRequests[1].env).toMatchObject({
      HUMANIZE2_JSONRPC_URL: "http://127.0.0.1:4772/jsonrpc",
      HUMANIZE2_RUN_ID: "run-child",
      HUMANIZE2_PARENT_RUN_ID: "run-parent"
    });
  });

  it("interrupts a running run and starts a linked continuation message", async () => {
    const seenRequests: AgentRequest[] = [];
    const runs = interruptibleCoordinator(seenRequests, ["run-original", "run-continuation"]);

    const original = runs.createRun({
      agent: "codex",
      prompt: "original direction",
      cwd: "/tmp/project",
      shortName: "drifting task",
      timeoutMs: 60_000
    });
    await waitUntil(() => seenRequests.length === 1);

    const continuation = await runs.sendMessage({
      runId: original.id,
      message: "new direction",
      shortName: "intervention"
    });
    const interrupted = await runs.waitForRun(original.id, 1_000);
    const continued = await runs.waitForRun(continuation.id, 1_000);

    expect(interrupted).toMatchObject({
      id: "run-original",
      status: "interrupted",
      backendSessionId: "agent-session-a",
      error: "Interrupted by Humanize2 message"
    });
    expect(interrupted.outputEvents.map((event) => event.text).join("")).toContain("new direction");
    expect(continued).toMatchObject({
      id: "run-continuation",
      status: "succeeded",
      continuedFromRunId: "run-original",
      interventionMessage: "new direction",
      shortName: "intervention",
      prompt: "new direction"
    });
    expect(seenRequests[1]).toMatchObject({
      prompt: "new direction",
      cwd: "/tmp/project",
      timeoutMs: 60_000,
      resumeSessionId: "agent-session-a",
      env: {
        HUMANIZE2_CONTINUED_FROM_RUN_ID: "run-original"
      }
    });
  });

  it("creates a continuation message for a completed run without changing its status", async () => {
    const seenRequests: AgentRequest[] = [];
    const runs = coordinator(seenRequests, ["run-done", "run-follow-up"]);

    const original = runs.createRun({ agent: "claude", prompt: "done task", cwd: "/tmp/project" });
    await runs.waitForRun(original.id, 1_000);

    const continuation = await runs.sendMessage({
      runId: original.id,
      message: "follow-up direction"
    });
    const originalAfterMessage = runs.getRun(original.id);
    const continued = await runs.waitForRun(continuation.id, 1_000);

    expect(originalAfterMessage.status).toBe("succeeded");
    expect(continued).toMatchObject({
      id: "run-follow-up",
      status: "succeeded",
      continuedFromRunId: "run-done",
      prompt: "follow-up direction"
    });
    expect(seenRequests[1]).toMatchObject({
      prompt: "follow-up direction",
      cwd: "/tmp/project"
    });
  });
});

describe("hub HTTP JSON-RPC server", () => {
  it("creates, waits for, and lists runs", async () => {
    const seenRequests: AgentRequest[] = [];
    const runs = coordinator(seenRequests, ["run-http"]);
    const server = createHubHttpServer(runs);
    openServers.push(server);
    const url = await listen(server);

    const createResult = await rpc(url, "run.create", {
      agent: "codex",
      shortName: "http run",
      prompt: "from http",
      cwd: "/tmp/project"
    });
    expect(createResult).toEqual({ runId: "run-http" });

    const waitResult = await rpc(url, "run.wait", { runId: "run-http", timeoutMs: 1_000 });
    expect(waitResult).toMatchObject({
      id: "run-http",
      shortName: "http run",
      status: "succeeded",
      timeoutMs: 21_600_000,
      result: {
        success: true,
        stdout: "handled from http"
      }
    });

    const listResult = await rpc(url, "run.list", {});
    expect(listResult).toMatchObject({
      runs: [
        {
          id: "run-http",
          agent: "codex",
          status: "succeeded"
        }
      ]
    });

    const sessionsResult = await rpc(url, "session.list", {});
    expect(sessionsResult).toEqual({ sessions: [] });

    const sessionsResponse = await fetch(`${url}/api/sessions`);
    expect(await sessionsResponse.json()).toEqual({ sessions: [] });

    const detailResponse = await fetch(`${url}/api/runs/run-http`);
    const detail = await detailResponse.json() as { outputEvents?: Array<{ stream: string; text: string }> };
    expect(detail.outputEvents).toMatchObject([
      {
        stream: "stdout",
        text: "out:from http"
      },
      {
        stream: "stderr",
        text: "err:from http"
      }
    ]);
  });

  it("exposes send_message over JSON-RPC", async () => {
    const seenRequests: AgentRequest[] = [];
    const runs = coordinator(seenRequests, ["run-http", "run-message"]);
    const server = createHubHttpServer(runs);
    openServers.push(server);
    const url = await listen(server);

    const info = await rpc(url, "system.info", {});
    expect(info).toMatchObject({
      methods: expect.arrayContaining(["run.send_message"])
    });

    await rpc(url, "run.create", {
      agent: "codex",
      prompt: "from http",
      cwd: "/tmp/project"
    });

    const messageResult = await rpc(url, "run.send_message", {
      runId: "run-http",
      message: "from http intervention",
      shortName: "http intervention"
    });
    expect(messageResult).toEqual({ runId: "run-message" });

    const continued = await rpc(url, "run.wait", { runId: "run-message", timeoutMs: 1_000 });
    expect(continued).toMatchObject({
      id: "run-message",
      shortName: "http intervention",
      continuedFromRunId: "run-http",
      prompt: "from http intervention"
    });
  });

  it("keeps a workflow agent active when JSON-RPC sends an interrupting message", async () => {
    const seenRequests: AgentRequest[] = [];
    const runs = interruptibleCoordinator(seenRequests, ["run-original", "run-continuation"], {
      abortDelayMs: 650,
      continuationDelayMs: 25
    });
    const workflows = new WorkflowCoordinator(runs, {
      idFactory: ids(["workflow-run", "artifact-result"]),
      now: () => "2026-05-14T18:00:00.000Z"
    });
    const server = createHubHttpServer(runs, { workflowCoordinator: workflows });
    openServers.push(server);
    const url = await listen(server);

    await workflows.loadHtml({
      html: `
        <h2-workflow id="external-intervention" name="External Intervention" version="0.1.0">
          <h2-manifest>
            <h2-capability name="agent" tools="codex"></h2-capability>
            <h2-capability name="artifact" schemas="result.v1"></h2-capability>
          </h2-manifest>
          <h2-template id="initial">original direction</h2-template>
          <h2-flow>
            <h2-agent id="worker" tool="codex" prompt="#initial" short-name="worker-a" timeout="10s">
              <h2-expect artifact="result" schema="result.v1"></h2-expect>
            </h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    });
    const workflow = workflows.start({ cartridgeId: "external-intervention", cwd: "/tmp/project" });
    await waitUntil(() => seenRequests.length === 1);

    const messageResult = await rpc(url, "run.send_message", {
      runId: "run-original",
      message: "new direction",
      shortName: "worker-b"
    });
    expect(messageResult).toEqual({ runId: "run-continuation" });

    workflows.deliverArtifact({
      workflowRunId: workflow.id,
      name: "result",
      schema: "result.v1",
      producer: "worker",
      content: { ok: true }
    });
    const finished = await workflows.waitForRun(workflow.id, 1_000);

    expect(finished.status).toBe("succeeded");
    expect(finished.nodeRunIds.worker).toBe("run-continuation");
    expect(finished.events).toEqual(expect.arrayContaining([
      expect.objectContaining({
        type: "agent.handed_off",
        data: expect.objectContaining({
          interruptedRunId: "run-original",
          continuationRunId: "run-continuation"
        })
      })
    ]));
  });

  it("infers the parent run for child spawns when exactly one active run matches the cwd", async () => {
    const seenRequests: AgentRequest[] = [];
    const runs = interruptibleCoordinator(seenRequests, ["run-parent", "run-child", "run-stop"]);
    const server = createHubHttpServer(runs);
    openServers.push(server);
    const url = await listen(server);

    await rpc(url, "run.create", {
      agent: "codex",
      prompt: "original direction",
      cwd: "/tmp/project"
    });
    await waitUntil(() => seenRequests.length === 1);

    const spawnResult = await rpc(url, "run.spawn_child", {
      agent: "claude",
      prompt: "child task",
      cwd: "/tmp/project"
    });
    expect(spawnResult).toEqual({ runId: "run-child" });

    const child = await rpc(url, "run.wait", { runId: "run-child", timeoutMs: 1_000 });
    expect(child).toMatchObject({
      id: "run-child",
      parentRunId: "run-parent",
      status: "succeeded"
    });

    await rpc(url, "run.send_message", {
      runId: "run-parent",
      message: "stop parent"
    });
  });

  it("serves the local dashboard shell", async () => {
    const runs = coordinator([], ["unused"]);
    const server = createHubHttpServer(runs);
    openServers.push(server);
    const url = await listen(server);

    const response = await fetch(url);
    const html = await response.text();

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("text/html");
    expect(html).toContain("Humanize2");
    expect(html).toContain('rel="icon"');
    expect(html).toContain('type="image/svg+xml"');
    expect(html).toContain("data:image/svg+xml");
    expect(html).toContain('<body data-theme="dark">');
    expect(html).toContain('const configuredDefaultTheme = "dark";');
    expect(html).toContain('localStorage.getItem("h2-theme") || configuredDefaultTheme');
    expect(html).toContain("/api/agent-sessions");
    expect(html).toContain("/api/sessions");
    expect(html).toContain("/api/workflows");
    expect(html).toContain("workflow-panel");
    expect(html).toContain("workflow-view-slot");
    expect(html).toContain("Workflow-specific Views");
    expect(html).toContain("margin-top: 18px");
    expect(html).toContain("padding-top: 14px");
    expect(html).toContain("border-top: 3px solid var(--border)");
    expect(html).toContain(".workflow-panel > .group-label");
    expect(html).toContain("renderWorkflowViews");
    expect(html).toContain("renderBoundWorkflowView");
    expect(html).toContain("data-h2-bind");
    expect(html).toContain("allowedWorkflowViewTags");
    expect(html).not.toContain("<pre>\" + escapeHtml(view.html || \"\") + \"</pre>");
    expect(html).toContain("Agent Sessions");
    expect(html).toContain("Flow Manager");
    expect(html).toContain("flow-list");
    expect(html).toContain("flow-manager-trace");
    expect(html).toContain("renderFlowManagerTrace");
    expect(html).toContain("flow-trace-card");
    expect(html).toContain("flow-trace-kicker");
    expect(html).toContain("trace-detail-grid");
    expect(html).toContain("traceKind");
    expect(html).toContain("Flow View");
    expect(html).toContain("renderFlowMap");
    expect(html).toContain("renderWorkflowFlowProjection");
    expect(html).toContain("renderFlowProjectionNode");
    expect(html).toContain("counterLabel");
    expect(html).toContain("renderWorkflowChat");
    expect(html).toContain("workflowChatEvents");
    expect(html).toContain("flow-loop");
    expect(html).toContain("flow-branch");
    expect(html).toContain("flow-projection-node.failed");
    expect(html).toContain("grid-template-columns: repeat(auto-fit, minmax(210px, 1fr))");
    expect(html).toContain("grid-column: 1 / -1");
    expect(html).not.toContain("renderDynamicSessionGraph");
    expect(html).not.toContain("workflowCaptainSession");
    expect(html).not.toContain("team-summary");
    expect(html).not.toContain("captain-spawned");
    expect(html).toContain("renderFlowTrace");
    expect(html).toContain("flow-trace-view");
    expect(html).toContain("flow-graph-view");
    expect(html).toContain("Group Chat");
    expect(html).toContain(">Timeline</span>");
    expect(html).toContain("Session Properties");
    expect(html).toContain("Session Transcript");
    expect(html).toContain("properties-title");
    expect(html).toContain("session-dashboard");
    expect(html).toContain("properties-drawer");
    expect(html).toContain("properties-toggle");
    expect(html).toContain("properties-collapsed");
    expect(html).toContain('class="fold-panel timeline-panel"');
    expect(html).toContain('class="timeline-content" id="gantt"');
    expect(html).toContain("grid-template-rows: auto auto");
    expect(html).toContain(".timeline-panel[open]");
    expect(html).toContain('data-resize="sidebar-width"');
    expect(html).toContain('data-resize="properties-width"');
    expect(html).toContain('data-resize="chat-height"');
    expect(html).toContain('data-resize="timeline-transcript-height"');
    expect(html).toContain("initResizableLayout()");
    expect(html).toContain("h2-layout-sidebar-width");
    expect(html).toContain("h2-layout-properties-width");
    expect(html).toContain("h2-layout-chat-height");
    expect(html).toContain("h2-layout-timeline-height");
    expect(html).toContain("h2-layout-transcript-height");
    expect(html).toContain("setPointerCapture");
    expect(html).toContain("cursor: col-resize");
    expect(html).toContain("cursor: row-resize");
    expect(html).toContain("chatResizeBounds");
    expect(html).toContain("visiblePanelMinimumHeight");
    expect(html).toContain("clampChatHeightToCurrentBounds");
    expect(html).toContain('state.kind === "chat-height"');
    expect(html).not.toContain(".layout-resizer::before");
    expect(html).not.toContain(".stack-resizer::before");
    expect(html).toContain("grid-template-rows: var(--chat-panel-height, minmax(320px, 1fr)) 8px minmax(0, 1fr)");
    expect(html).toContain("body.timeline-collapsed.transcript-collapsed .workbench");
    expect(html).toContain("grid-template-rows: minmax(0, 1fr) 0 max-content");
    expect(html).toContain("body.timeline-collapsed.transcript-collapsed .chat-resizer");
    expect(html).toContain("grid-template-rows: minmax(120px, var(--timeline-panel-height, min(24vh, 280px))) 8px minmax(0, 1fr)");
    expect(html).toContain("scrollbar-gutter: stable");
    expect(html).not.toContain("grid-template-rows: minmax(180px, 24vh) auto");
    expect(html).toContain("metric-strip");
    expect(html).toContain("property-group");
    expect(html).toContain('Session Properties: " + escapeHtml(session.title || session.sessionId)');
    expect(html).toContain("brand-lockup");
    expect(html).toContain("polyarch-mark");
    expect(html).toContain("brand-copy");
    expect(html).toContain("brand-byline");
    expect(html).toContain('href="https://github.com/PolyArch/humanize"');
    expect(html).toContain('class="brand-version">v' + packageVersion + "</span>");
    expect(html).toContain('href="https://github.com/SihaoLiu"');
    expect(html).toContain(">Sihao Liu</a>");
    expect(html).toContain('href="https://github.com/PolyArch/humanize/graphs/contributors"');
    expect(html).toContain(">community</a>");
    expect(html).not.toContain("chip-a");
    expect(html).not.toContain("chip-b");
    expect(html).not.toContain("pixel-chip");
    expect(html).toContain("Tool");
    expect(html).toContain("Tool/Model");
    expect(html).toContain("toolModelLabel");
    expect(html).toContain('agent + ": " + model + " [" + session.reasoningEffort + "]"');
    expect(html).not.toContain("Tool / Model");
    expect(html).toContain("Model");
    expect(html).toContain("Working Path");
    expect(html).toContain("Session ID");
    expect(html).toContain("Latest Context");
    expect(html).toContain("Messages");
    expect(html).toContain('received " + String(counts.received) + " / sent " + String(counts.sent)');
    expect(html).toContain("Input Tokens");
    expect(html).toContain("Cached Input");
    expect(html).toContain("Output Tokens");
    expect(html).toContain("Total Tokens");
    expect(html).toContain("follow-output");
    expect(html).toContain("theme-toggle");
    expect(html).toContain("all-panels-toggle");
    expect(html).toContain("sidebar-toggle");
    expect(html).toContain("timeline-toggle");
    expect(html).toContain("transcript-toggle");
    expect(html).toContain("setAllPanelsCollapsed");
    expect(html).toContain("updateAllPanelsToggle");
    expect(html).toContain('toggle.textContent = collapsed ? "Show" : "Hide"');
    expect(html).toContain("setFoldPanelCollapsed");
    expect(html).toContain("preventSummaryToggle");
    expect(html).toContain('timelineToggleElement.addEventListener("click", (event) => {\n        event.preventDefault();');
    expect(html).toContain('transcriptToggleElement.addEventListener("click", (event) => {\n        event.preventDefault();');
    expect(html).toContain("timeline-collapsed");
    expect(html).toContain("transcript-collapsed");
    expect(html).toContain("align-content: start");
    expect(html).toContain("body.timeline-collapsed.transcript-collapsed .details-stack");
    expect(html).toContain("grid-template-rows: max-content 0 minmax(0, 1fr)");
    expect(html).toContain("grid-template-rows: minmax(0, 1fr) 0 max-content");
    expect(html).toContain("grid-template-rows: max-content 0 max-content");
    expect(html).toContain("body.sidebar-collapsed .sidebar .panel-title .pixel-button");
    expect(html).toContain("body.properties-collapsed .properties-drawer .panel-title .pixel-button");
    expect(html).toContain(".sidebar { grid-column: 1; }");
    expect(html).toContain(".workbench { grid-column: 3; }");
    expect(html).toContain(".properties-drawer { grid-column: 5; }");
    expect(html).toContain("pointer-events: none");
    expect(html).toContain("box-shadow: none");
    expect(html).toContain("top: 134px");
    expect(html).toContain("height: 46px");
    expect(html).toContain("background: var(--surface-strong)");
    expect(html).toContain("transform: rotate(-90deg)");
    expect(html).toContain("transform: rotate(90deg)");
    expect(html).toContain("transform-origin: left top");
    expect(html).toContain("transform-origin: right top");
    expect(html).toContain('sidebarToggleElement.textContent = collapsed ? "Sessions" : "Hide"');
    expect(html).toContain('propertiesToggleElement.textContent = collapsed ? "Properties" : "Hide"');
    expect(html).toContain("group-chat");
    expect(html).toContain("message-toggle");
    expect(html).toContain(".chat-event.user");
    expect(html).toContain(".chat-event.user-system");
    expect(html).toContain("justify-self: end");
    expect(html).toContain("grid-template-columns: minmax(0, 1fr) 38px");
    expect(html).toContain("margin-right: 46px");
    expect(html).toContain('kind: fromWorkflow ? "system" : (parent === undefined ? "user" : (entry.kind === "intervention" ? "intervention" : "message"))');
    expect(html).toContain('author: fromWorkflow ? (origin.sender || "Flow Manager")');
    expect(html).toContain('kind: session.parentSessionId ? "system" : "user-system"');
    expect(html).toContain('kind: parent?.parentSessionId ? "system" : "user-system"');
    expect(html).toContain("transcript-view");
    expect(html).toContain("transcript codex");
    expect(html).toContain("transcript claude");
    expect(html).toContain(".gantt");
    expect(html).toContain("renderJsonLine");
    expect(html).toContain("renderGroupChat");
    expect(html).toContain("workflowArtifactChatTarget");
    expect(html).toContain('if (name === "round-summary")');
    expect(html).toContain('return "reviewer"');
    expect(html).toContain('if (name === "review-verdict")');
    expect(html).toContain('return "builder"');
    expect(html).toContain("formatArtifactContentForChat");
    expect(html).toContain("toggleLongMessage");
    expect(html).toContain("messageCounts");
    expect(html).toContain("hasActiveSelectionInside(element)");
    expect(html).toContain("window.getSelection");
    expect(html).not.toContain("Logical Hierarchy and Timeline");
    expect(html).not.toContain("Agent Session Timeline");
    expect(html).not.toContain("lifecycle view");
    expect(html).not.toContain("Agent Session Graph");
    expect(html).not.toContain("Session Input History");
    expect(html).not.toContain("Session Log");
    expect(html).not.toContain("Session Output");
    expect(html).not.toContain("Continued From");
    expect(html).not.toContain("Vendor Session ID");
    expect(html).not.toContain("Context Usage");
    expect(html).not.toContain("selected agent session");
    expect(html).not.toContain("writing-mode: vertical-rl");
    expect(html).not.toContain("timeline-drawer");
    expect(html).not.toContain("Attempts");
    expect(html).not.toContain("Interventions");
    expect(html).not.toContain("Tool Calls");
  });

  it("serves dashboard scripts that parse in the browser", async () => {
    const runs = coordinator([], ["unused"]);
    const server = createHubHttpServer(runs);
    openServers.push(server);
    const url = await listen(server);

    const response = await fetch(url);
    const html = await response.text();
    const scripts = Array.from(html.matchAll(/<script>([\s\S]*?)<\/script>/g), (match) => match[1]);

    expect(scripts.length).toBeGreaterThan(0);
    for (const script of scripts) {
      expect(() => new vm.Script(script)).not.toThrow();
    }
  });

  it("pre-resolves data-h2-bind under the shared workflow expression grammar", async () => {
    const runs = coordinator([], ["unused"]);
    const workflows = new WorkflowCoordinator(runs, {
      idFactory: ids(["workflow-run", "artifact-1", "artifact-2"])
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="binding-flow" name="Binding Flow" version="0.1.0">
          <h2-state><h2-board id="team-board" schema="team.board.v1"></h2-board></h2-state>
          <h2-flow></h2-flow>
          <h2-view slot="properties">
            <section>
              <h3>Workflow</h3>
              <p>Status: <span data-h2-bind="board.team-board.status">-</span></p>
              <p>Bracketed: <span data-h2-bind="board.team-board.[deep.field]">-</span></p>
              <p>Latest: <span data-h2-bind="artifact.report@latest.title">-</span></p>
              <p>Var: <span data-h2-bind="var.greeting">-</span></p>
            </section>
          </h2-view>
        </h2-workflow>
      `
    });
    const run = workflows.start({ cartridgeId: "binding-flow" });
    workflows.patchBoard({
      workflowRunId: run.id,
      boardId: "team-board",
      patch: { status: "going", "deep.field": "found" }
    });
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "report",
      content: { title: "first" }
    });
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "report",
      content: { title: "second" }
    });
    const server = createHubHttpServer(runs, { workflowCoordinator: workflows });
    openServers.push(server);
    const url = await listen(server);

    const response = await fetch(`${url}/api/workflows`);
    const payload = await response.json() as { workflows: Array<{ views: Array<{ html: string }> }> };
    const rendered = payload.workflows[0].views[0].html;
    expect(rendered).toContain("going");
    expect(rendered).toContain("found");
    expect(rendered).toContain("second");
    // var.greeting was never set; the placeholder text should remain
    expect(rendered).toContain("-");
  });

  it("aligns view tag allowlist with the spec and drops legacy passive tags", async () => {
    const runs = coordinator([], ["unused"]);
    const server = createHubHttpServer(runs);
    openServers.push(server);
    const url = await listen(server);

    const response = await fetch(url);
    const html = await response.text();
    // Spec tag set should include time and h5/h6 but not header/footer/b/i/small
    expect(html).toContain('"time"');
    expect(html).toContain('"h5"');
    expect(html).toContain('"h6"');
    const allowlistMatch = /allowedWorkflowViewTags\s*=\s*new\s*Set\(\[([^\]]*)\]/.exec(html);
    expect(allowlistMatch).not.toBeNull();
    const allowlistBody = allowlistMatch![1];
    expect(allowlistBody).not.toContain('"header"');
    expect(allowlistBody).not.toContain('"footer"');
    expect(allowlistBody).not.toContain('"b"');
    expect(allowlistBody).not.toContain('"i"');
    expect(allowlistBody).not.toContain('"small"');
  });

  it("passes workflow.start cwd through JSON-RPC to workflow-spawned agents", async () => {
    const seenRequests: AgentRequest[] = [];
    const runs = coordinator(seenRequests, ["agent-run"]);
    const workflows = new WorkflowCoordinator(runs, {
      idFactory: ids(["workflow-run"])
    });
    const server = createHubHttpServer(runs, { workflowCoordinator: workflows });
    openServers.push(server);
    const url = await listen(server);

    await rpc(url, "workflow.load_html", {
      html: `
        <h2-workflow id="cwd-rpc-flow" name="Cwd RPC Flow" version="0.1.0">
          <h2-manifest><h2-capability name="agent" tools="codex"></h2-capability></h2-manifest>
          <h2-template id="prompt">Use the run cwd.</h2-template>
          <h2-flow>
            <h2-agent id="worker" tool="codex" prompt="#prompt"></h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    });
    await rpc(url, "workflow.start", {
      cartridgeId: "cwd-rpc-flow",
      cwd: "/tmp/humanize2-workflow-rpc-project"
    });
    await waitUntil(() => seenRequests.length >= 1);

    expect(seenRequests[0].cwd).toBe("/tmp/humanize2-workflow-rpc-project");
  });

  it("exposes workflow records for the dashboard", async () => {
    const runs = coordinator([], ["unused"]);
    const workflows = new WorkflowCoordinator(runs, {
      idFactory: ids(["workflow-run", "workflow-run-no-view"])
    });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="dashboard-flow" name="Dashboard Flow" version="0.1.0">
          <h2-state><h2-board id="dashboard-board" schema="dashboard.board.v1"></h2-board></h2-state>
          <h2-flow></h2-flow>
          <h2-view slot="properties"><section>Dashboard workflow view</section></h2-view>
        </h2-workflow>
      `
    });
    workflows.start({ cartridgeId: "dashboard-flow" });
    await workflows.loadHtml({
      html: `
        <h2-workflow id="no-view-flow" name="No View Flow" version="0.1.0">
          <h2-flow></h2-flow>
        </h2-workflow>
      `
    });
    workflows.start({ cartridgeId: "no-view-flow" });
    const server = createHubHttpServer(runs, { workflowCoordinator: workflows });
    openServers.push(server);
    const url = await listen(server);

    const response = await fetch(`${url}/api/workflows`);
    const payload = await response.json() as { workflows: Array<{ id: string; cartridgeId: string; boards: unknown[]; views: unknown[] }> };

    expect(payload.workflows).toMatchObject([
      {
        id: "workflow-run",
        cartridgeId: "dashboard-flow",
        status: "succeeded",
        boards: [{ id: "dashboard-board" }],
        views: [{ slot: "properties", html: "<section>Dashboard workflow view</section>" }]
      },
      {
        id: "workflow-run-no-view",
        cartridgeId: "no-view-flow",
        status: "succeeded",
        views: []
      }
    ]);
  });
});

async function listen(server: Server): Promise<string> {
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
  const address = server.address();
  if (address === null || typeof address === "string") {
    throw new Error("missing server address");
  }
  return `http://127.0.0.1:${address.port}`;
}

async function rpc(baseUrl: string, method: string, params: unknown): Promise<unknown> {
  const response = await fetch(`${baseUrl}/jsonrpc`, {
    method: "POST",
    headers: {
      "content-type": "application/json"
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method,
      params
    })
  });

  const payload = await response.json() as { result?: unknown; error?: { message: string } };
  if (payload.error !== undefined) {
    throw new Error(payload.error.message);
  }

  return payload.result;
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
