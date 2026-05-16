import { readFileSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";

import type { AgentId } from "../agents/types.js";
import type { AgentModelDefaultsByAgent, DashboardTheme } from "../config.js";
import type { RunAgentInput } from "../service.js";
import { buildAgentSessions } from "./agent-sessions.js";
import { dashboardHtml } from "./dashboard.js";
import type { AgentMessageOrigin, AgentRunCoordinator } from "./runs.js";
import { loadVendorSessionMetadataForRuns } from "./vendor-metadata.js";
import type { WorkflowCoordinator } from "../workflows/coordinator.js";
import type { DeliverArtifactInput, PatchBoardInput, WorkflowRunRecord } from "../workflows/types.js";
import { resolvePath } from "../workflows/expression.js";

const appVersion = readPackageVersion();

interface JsonRpcRequest {
  jsonrpc: "2.0";
  id?: string | number | null;
  method: string;
  params?: unknown;
}

interface JsonRpcError {
  code: number;
  message: string;
  data?: unknown;
}

export interface HubHttpServerOptions {
  agentDefaults?: AgentModelDefaultsByAgent;
  defaultTheme?: DashboardTheme;
  workflowCoordinator?: WorkflowCoordinator;
}

export function createHubHttpServer(coordinator: AgentRunCoordinator, options: HubHttpServerOptions = {}): Server {
  return createServer(async (request, response) => {
    try {
      await routeRequest(coordinator, options, request, response);
    } catch (error) {
      writeJson(response, 500, {
        error: error instanceof Error ? error.message : String(error)
      });
    }
  });
}

async function routeRequest(
  coordinator: AgentRunCoordinator,
  options: HubHttpServerOptions,
  request: IncomingMessage,
  response: ServerResponse
): Promise<void> {
  const url = new URL(request.url ?? "/", "http://127.0.0.1");

  if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/index.html")) {
    response.writeHead(200, {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store"
    });
    response.end(dashboardHtml({ defaultTheme: options.defaultTheme, appVersion }));
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/runs") {
    writeJson(response, 200, { runs: coordinator.listRuns() });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/sessions") {
    writeJson(response, 200, { sessions: coordinator.listSessions() });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/agent-sessions") {
    const runs = coordinator.listRuns();
    writeJson(response, 200, {
      agentSessions: buildAgentSessions(runs, {
        agentDefaults: options.agentDefaults,
        metadataByVendorSessionId: loadVendorSessionMetadataForRuns(runs)
      })
    });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/workflows") {
    writeJson(response, 200, {
      workflows: options.workflowCoordinator?.listRunsWithRenderedViews() ?? []
    });
    return;
  }

  if (request.method === "GET" && url.pathname.startsWith("/api/runs/")) {
    const runId = decodeURIComponent(url.pathname.slice("/api/runs/".length));
    writeJson(response, 200, coordinator.getRun(runId));
    return;
  }

  if (request.method === "POST" && url.pathname === "/jsonrpc") {
    const body = await readBody(request);
    const rpcRequest = JSON.parse(body) as JsonRpcRequest;
    const rpcResponse = await handleRpc(coordinator, options, rpcRequest);
    writeJson(response, 200, rpcResponse);
    return;
  }

  writeJson(response, 404, { error: "not found" });
}

async function handleRpc(
  coordinator: AgentRunCoordinator,
  options: HubHttpServerOptions,
  request: JsonRpcRequest
): Promise<unknown> {
  if (request.jsonrpc !== "2.0" || typeof request.method !== "string") {
    return jsonRpcFailure(request.id, { code: -32600, message: "Invalid JSON-RPC request" });
  }

  try {
    const result = await dispatchRpc(coordinator, options, request.method, request.params);
    return {
      jsonrpc: "2.0",
      id: request.id ?? null,
      result
    };
  } catch (error) {
    return jsonRpcFailure(request.id, {
      code: -32603,
      message: error instanceof Error ? error.message : String(error)
    });
  }
}

async function dispatchRpc(
  coordinator: AgentRunCoordinator,
  options: HubHttpServerOptions,
  method: string,
  params: unknown
): Promise<unknown> {
  const workflowMethods = [
    "workflow.load_html",
    "workflow.start",
    "workflow.get",
    "workflow.list",
    "workflow.wait",
    "artifact.deliver",
    "artifact.get",
    "board.patch",
    "board.get",
    "human.request",
    "human.answer",
    "event.emit",
    "view.publish"
  ];
  switch (method) {
    case "system.info":
      return {
        name: "humanize2",
        methods: [
          "system.info",
          "agent.status",
          "run.create",
          "run.spawn_child",
          "run.send_message",
          "run.get",
          "run.list",
          "run.wait",
          "session.list",
          ...(options.workflowCoordinator === undefined ? [] : workflowMethods)
        ]
      };
    case "agent.status":
      return coordinator.agentStatus(asObject(params));
    case "run.create": {
      const input = asRunInput(params);
      const parentRunId = asOptionalString((params as { parentRunId?: unknown }).parentRunId, "parentRunId");
      const run = coordinator.createRun(input, { parentRunId });
      return { runId: run.id };
    }
    case "run.spawn_child": {
      const object = asObject(params);
      const input = asRunInput(object);
      const parentRunId =
        asOptionalString(object.parentRunId, "parentRunId") ?? coordinator.inferActiveParentRunId(input);
      const run = coordinator.createRun(input, { parentRunId });
      return { runId: run.id };
    }
    case "run.send_message": {
      const input = asSendMessageInput(params);
      const run = options.workflowCoordinator === undefined
        ? await coordinator.sendMessage(input)
        : await options.workflowCoordinator.sendMessage(input);
      return { runId: run.id };
    }
    case "run.get": {
      const object = asObject(params);
      return coordinator.getRun(asRequiredString(object.runId, "runId"));
    }
    case "run.list":
      return { runs: coordinator.listRuns() };
    case "session.list":
      return { sessions: coordinator.listSessions() };
    case "run.wait": {
      const object = asObject(params);
      return coordinator.waitForRun(
        asRequiredString(object.runId, "runId"),
        asOptionalNumber(object.timeoutMs, "timeoutMs") ?? 600_000
      );
    }
    case "workflow.load_html": {
      const workflow = requireWorkflowCoordinator(options);
      const cartridge = await workflow.loadHtml(asLoadWorkflowHtmlInput(params));
      return { cartridgeId: cartridge.id };
    }
    case "workflow.start": {
      const workflow = requireWorkflowCoordinator(options);
      const object = asObject(params);
      const run = workflow.start({
        cartridgeId: asRequiredString(object.cartridgeId, "cartridgeId"),
        cwd: asOptionalString(object.cwd, "cwd"),
        agentToolOverride: asOptionalAgentTool(object.agentToolOverride, "agentToolOverride")
      });
      return { workflowRunId: run.id };
    }
    case "workflow.get": {
      const workflow = requireWorkflowCoordinator(options);
      const object = asObject(params);
      return workflow.getRun(asRequiredString(object.workflowRunId, "workflowRunId"));
    }
    case "workflow.list": {
      const workflow = requireWorkflowCoordinator(options);
      return { workflows: workflow.listRuns() };
    }
    case "workflow.wait": {
      const workflow = requireWorkflowCoordinator(options);
      const object = asObject(params);
      return workflow.waitForRun(
        asRequiredString(object.workflowRunId, "workflowRunId"),
        asOptionalNumber(object.timeoutMs, "timeoutMs") ?? 600_000
      );
    }
    case "artifact.deliver": {
      const workflow = requireWorkflowCoordinator(options);
      const artifact = workflow.deliverArtifact(asDeliverArtifactInput(params));
      return { artifactId: artifact.id };
    }
    case "artifact.get": {
      const workflow = requireWorkflowCoordinator(options);
      const object = asObject(params);
      return workflow.getArtifact({
        workflowRunId: asRequiredString(object.workflowRunId, "workflowRunId"),
        name: asRequiredString(object.name, "name")
      });
    }
    case "board.patch": {
      const workflow = requireWorkflowCoordinator(options);
      return workflow.patchBoard(asPatchBoardInput(params));
    }
    case "board.get": {
      const workflow = requireWorkflowCoordinator(options);
      const object = asObject(params);
      return workflow.getBoard({
        workflowRunId: asRequiredString(object.workflowRunId, "workflowRunId"),
        boardId: asRequiredString(object.boardId, "boardId")
      });
    }
    case "human.request": {
      const workflow = requireWorkflowCoordinator(options);
      const object = asObject(params);
      return workflow.humanRequest({
        workflowRunId: asRequiredString(object.workflowRunId, "workflowRunId"),
        prompt: asOptionalString(object.prompt, "prompt"),
        artifact: asRequiredString(object.artifact, "artifact"),
        schema: asOptionalString(object.schema, "schema"),
        vertex: asOptionalString(object.vertex, "vertex")
      });
    }
    case "human.answer": {
      const workflow = requireWorkflowCoordinator(options);
      const object = asObject(params);
      return workflow.humanAnswer({
        workflowRunId: asRequiredString(object.workflowRunId, "workflowRunId"),
        artifact: asRequiredString(object.artifact, "artifact"),
        schema: asOptionalString(object.schema, "schema"),
        content: object.content
      });
    }
    case "event.emit": {
      const workflow = requireWorkflowCoordinator(options);
      const object = asObject(params);
      return workflow.emitEvent({
        workflowRunId: asRequiredString(object.workflowRunId, "workflowRunId"),
        type: asRequiredString(object.type, "type"),
        data: object.data
      });
    }
    case "view.publish": {
      const workflow = requireWorkflowCoordinator(options);
      const object = asObject(params);
      return workflow.publishView({
        workflowRunId: asRequiredString(object.workflowRunId, "workflowRunId"),
        slot: asRequiredString(object.slot, "slot"),
        html: asOptionalString(object.html, "html"),
        data: object.data
      });
    }
    default:
      throw new Error(`Unknown method: ${method}`);
  }
}

function requireWorkflowCoordinator(options: HubHttpServerOptions): WorkflowCoordinator {
  if (options.workflowCoordinator === undefined) {
    throw new Error("Workflow coordinator is not configured");
  }
  return options.workflowCoordinator;
}

function asLoadWorkflowHtmlInput(params: unknown) {
  const object = asObject(params);
  return {
    html: asOptionalString(object.html, "html"),
    path: asOptionalString(object.path, "path"),
    sourcePath: asOptionalString(object.sourcePath, "sourcePath")
  };
}

function asOptionalAgentTool(value: unknown, field: string) {
  if (value === undefined) {
    return undefined;
  }
  const parsed = asRequiredString(value, field);
  if (parsed !== "codex" && parsed !== "claude") {
    throw new Error(`${field} must be codex or claude`);
  }
  return parsed;
}

function asDeliverArtifactInput(params: unknown): DeliverArtifactInput {
  const object = asObject(params);
  return {
    workflowRunId: asRequiredString(object.workflowRunId, "workflowRunId"),
    name: asRequiredString(object.name, "name"),
    schema: asOptionalString(object.schema, "schema"),
    producer: asOptionalString(object.producer, "producer"),
    content: object.content
  };
}

function asPatchBoardInput(params: unknown): PatchBoardInput {
  const object = asObject(params);
  return {
    workflowRunId: asRequiredString(object.workflowRunId, "workflowRunId"),
    boardId: asRequiredString(object.boardId, "boardId"),
    patch: asObject(object.patch)
  };
}

function asSendMessageInput(params: unknown) {
  const object = asObject(params);

  return {
    runId: asRequiredString(object.runId, "runId"),
    message: asRequiredString(object.message, "message"),
    shortName: asOptionalString(object.shortName, "shortName"),
    timeoutMs: asOptionalNumber(object.timeoutMs, "timeoutMs"),
    interrupt: asOptionalBoolean(object.interrupt, "interrupt"),
    messageOrigin: asOptionalMessageOrigin(object.messageOrigin)
  };
}

function asOptionalMessageOrigin(value: unknown): AgentMessageOrigin | undefined {
  if (value === undefined) {
    return undefined;
  }
  const object = asObject(value);
  const kind = asRequiredString(object.kind, "messageOrigin.kind");
  if (kind !== "user" && kind !== "agent" && kind !== "workflow") {
    throw new Error("messageOrigin.kind must be user, agent, or workflow");
  }
  return {
    kind,
    sender: asOptionalString(object.sender, "messageOrigin.sender"),
    sourceRunId: asOptionalString(object.sourceRunId, "messageOrigin.sourceRunId"),
    workflowRunId: asOptionalString(object.workflowRunId, "messageOrigin.workflowRunId"),
    workflowVertexId: asOptionalString(object.workflowVertexId, "messageOrigin.workflowVertexId")
  };
}

function asRunInput(params: unknown): RunAgentInput {
  const object = asObject(params);
  const agent = asAgent(object.agent);

  return {
    agent,
    prompt: asRequiredString(object.prompt, "prompt"),
    shortName: asOptionalString(object.shortName, "shortName"),
    cwd: asOptionalString(object.cwd, "cwd"),
    model: asOptionalString(object.model, "model"),
    reasoningEffort: asOptionalString(object.reasoningEffort, "reasoningEffort"),
    timeoutMs: asOptionalNumber(object.timeoutMs, "timeoutMs"),
    sandbox: asOptionalString(object.sandbox, "sandbox") as RunAgentInput["sandbox"],
    permissionMode: asOptionalString(object.permissionMode, "permissionMode") as RunAgentInput["permissionMode"],
    extraArgs: asOptionalStringArray(object.extraArgs, "extraArgs"),
    env: asOptionalStringRecord(object.env, "env")
  };
}

function asAgent(value: unknown): AgentId {
  if (value === "codex" || value === "claude") {
    return value;
  }

  throw new Error("agent must be codex or claude");
}

function asObject(value: unknown): Record<string, unknown> {
  if (value === undefined) {
    return {};
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("params must be an object");
  }

  return value as Record<string, unknown>;
}

function asRequiredString(value: unknown, name: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${name} must be a non-empty string`);
  }

  return value;
}

function asOptionalString(value: unknown, name: string): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "string") {
    throw new Error(`${name} must be a string`);
  }

  return value;
}

function asOptionalNumber(value: unknown, name: string): number | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    throw new Error(`${name} must be a positive number`);
  }

  return value;
}

function asOptionalBoolean(value: unknown, name: string): boolean | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "boolean") {
    throw new Error(`${name} must be a boolean`);
  }

  return value;
}

function asOptionalStringArray(value: unknown, name: string): string[] | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new Error(`${name} must be an array of strings`);
  }

  return value;
}

function asOptionalStringRecord(value: unknown, name: string): Record<string, string> | undefined {
  if (value === undefined) {
    return undefined;
  }
  const object = asObject(value);
  for (const [key, item] of Object.entries(object)) {
    if (typeof item !== "string") {
      throw new Error(`${name}.${key} must be a string`);
    }
  }

  return object as Record<string, string>;
}

function readBody(request: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let body = "";

    request.setEncoding("utf8");
    request.on("data", (chunk: string) => {
      body += chunk;
      if (body.length > 1_000_000) {
        reject(new Error("request body is too large"));
        request.destroy();
      }
    });
    request.on("end", () => resolve(body));
    request.on("error", reject);
  });
}

function writeJson(response: ServerResponse, statusCode: number, value: unknown): void {
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store"
  });
  response.end(JSON.stringify(value, null, 2));
}

function readPackageVersion(): string {
  try {
    const packageJson = JSON.parse(readFileSync(new URL("../../package.json", import.meta.url), "utf8")) as { version?: unknown };
    return typeof packageJson.version === "string" && packageJson.version.trim().length > 0 ? packageJson.version.trim() : "unknown";
  } catch {
    return "unknown";
  }
}

function jsonRpcFailure(id: JsonRpcRequest["id"], error: JsonRpcError): unknown {
  return {
    jsonrpc: "2.0",
    id: id ?? null,
    error
  };
}
