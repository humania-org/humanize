import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import { createDefaultBackends } from "./agents/registry.js";
import type { AgentId, AgentRequest } from "./agents/types.js";
import { callHubRpc } from "./hub-client.js";
import { HumanizeService } from "./service.js";

const agentSchema = z.enum(["codex", "claude"]);
const runInputSchema = {
  agent: agentSchema,
  prompt: z.string().min(1),
  shortName: z.string().min(1).optional(),
  cwd: z.string().optional(),
  model: z.string().optional(),
  reasoningEffort: z.string().min(1).optional(),
  timeoutMs: z.number().int().positive().optional(),
  sandbox: z.enum(["read-only", "workspace-write", "danger-full-access"]).optional(),
  permissionMode: z.enum(["acceptEdits", "auto", "bypassPermissions", "default", "dontAsk", "plan"]).optional(),
  extraArgs: z.array(z.string()).optional(),
  env: z.record(z.string()).optional()
};

const directRunInputSchema = {
  prompt: z.string().min(1),
  shortName: z.string().min(1).optional(),
  cwd: z.string().optional(),
  model: z.string().optional(),
  reasoningEffort: z.string().min(1).optional(),
  timeoutMs: z.number().int().positive().optional(),
  sandbox: z.enum(["read-only", "workspace-write", "danger-full-access"]).optional(),
  permissionMode: z.enum(["acceptEdits", "auto", "bypassPermissions", "default", "dontAsk", "plan"]).optional(),
  extraArgs: z.array(z.string()).optional(),
  env: z.record(z.string()).optional()
};

const statusInputSchema = {
  agent: agentSchema.optional()
};

const sendMessageInputSchema = {
  runId: z.string().min(1),
  message: z.string().min(1),
  shortName: z.string().min(1).optional(),
  timeoutMs: z.number().int().positive().optional(),
  interrupt: z.boolean().optional()
};

const spawnChildInputSchema = {
  ...runInputSchema,
  parentRunId: z.string().min(1).optional()
};

const waitInputSchema = {
  runId: z.string().min(1),
  timeoutMs: z.number().int().positive().optional()
};

const workflowLoadHtmlInputSchema = {
  html: z.string().min(1).optional(),
  path: z.string().min(1).optional(),
  sourcePath: z.string().min(1).optional()
};

const workflowStartInputSchema = {
  cartridgeId: z.string().min(1),
  cwd: z.string().min(1).optional(),
  agentToolOverride: z.enum(["codex", "claude"]).optional()
};

const workflowRunInputSchema = {
  workflowRunId: z.string().min(1)
};

const workflowWaitInputSchema = {
  workflowRunId: z.string().min(1),
  timeoutMs: z.number().int().positive().optional()
};

const artifactDeliverInputSchema = {
  workflowRunId: z.string().min(1),
  name: z.string().min(1),
  schema: z.string().min(1).optional(),
  producer: z.string().min(1).optional(),
  content: z.unknown()
};

const artifactGetInputSchema = {
  workflowRunId: z.string().min(1),
  name: z.string().min(1)
};

const boardPatchInputSchema = {
  workflowRunId: z.string().min(1),
  boardId: z.string().min(1),
  patch: z.record(z.unknown())
};

const boardGetInputSchema = {
  workflowRunId: z.string().min(1),
  boardId: z.string().min(1)
};

const humanRequestInputSchema = {
  workflowRunId: z.string().min(1),
  prompt: z.string().min(1).optional(),
  artifact: z.string().min(1),
  schema: z.string().min(1).optional(),
  vertex: z.string().min(1).optional()
};

const humanAnswerInputSchema = {
  workflowRunId: z.string().min(1),
  artifact: z.string().min(1),
  schema: z.string().min(1).optional(),
  content: z.unknown()
};

const eventEmitInputSchema = {
  workflowRunId: z.string().min(1),
  type: z.string().min(1),
  data: z.unknown().optional()
};

const viewPublishInputSchema = {
  workflowRunId: z.string().min(1),
  slot: z.string().min(1),
  html: z.string().optional(),
  data: z.unknown().optional()
};

export function createHumanizeMcpServer(service = new HumanizeService(createDefaultBackends())): McpServer {
  const server = new McpServer({
    name: "humanize2",
    version: "0.1.0"
  });

  server.registerTool(
    "agent_status",
    {
      title: "Get agent availability",
      description: "Report availability and versions for Codex and Claude CLI backends.",
      inputSchema: statusInputSchema,
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
      }
    },
    async (args) => jsonContent(await service.agentStatus(args))
  );

  server.registerTool(
    "agent_run",
    {
      title: "Run an external coding agent",
      description: "Run a single prompt through a selected CLI-backed agent.",
      inputSchema: runInputSchema,
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
      }
    },
    async (args) => jsonContent(await service.runAgent(args))
  );

  server.registerTool(
    "agent_spawn_child",
    {
      title: "Spawn a managed child run",
      description: "Start a hub-managed child run. If parentRunId is omitted, the current Humanize2 run environment is used.",
      inputSchema: spawnChildInputSchema,
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
      }
    },
    async (args) => jsonContent(await callHubRpc({
      url: process.env.HUMANIZE2_JSONRPC_URL ?? "http://127.0.0.1:4772/jsonrpc",
      method: "run.spawn_child",
      params: {
        ...args,
        parentRunId: args.parentRunId ?? process.env.HUMANIZE2_RUN_ID
      }
    }))
  );

  server.registerTool(
    "agent_send_message",
    {
      title: "Send a message to a managed run",
      description: "Send a message to a Humanize2 hub run, interrupting and continuing it when needed.",
      inputSchema: sendMessageInputSchema,
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
      }
    },
    async (args) => jsonContent(await callHubRpc({
      url: process.env.HUMANIZE2_JSONRPC_URL ?? "http://127.0.0.1:4772/jsonrpc",
      method: "run.send_message",
      params: {
        ...args,
        ...messageOriginFromEnvironment(process.env)
      }
    }))
  );

  server.registerTool(
    "agent_wait",
    {
      title: "Wait for a managed run",
      description: "Wait for a Humanize2 hub run to reach a terminal status.",
      inputSchema: waitInputSchema,
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
      }
    },
    async (args) => jsonContent(await callHubRpc({
      url: process.env.HUMANIZE2_JSONRPC_URL ?? "http://127.0.0.1:4772/jsonrpc",
      method: "run.wait",
      params: args
    }))
  );

  registerDirectAgentTool(server, service, "codex", "codex_run", "Run Codex CLI");
  registerDirectAgentTool(server, service, "claude", "claude_run", "Run Claude Code");
  registerHubForwardingTool(server, "workflow_load_html", "Load an HTML workflow cartridge", "workflow.load_html", workflowLoadHtmlInputSchema);
  registerHubForwardingTool(server, "workflow_start", "Start a loaded workflow cartridge", "workflow.start", workflowStartInputSchema);
  registerHubForwardingTool(server, "workflow_get", "Inspect a workflow run", "workflow.get", workflowRunInputSchema);
  registerHubForwardingTool(server, "workflow_list", "List loaded workflow runs", "workflow.list", {}, true);
  registerHubForwardingTool(server, "workflow_wait", "Wait for a workflow run", "workflow.wait", workflowWaitInputSchema, true);
  registerHubForwardingTool(server, "artifact_deliver", "Deliver a workflow artifact", "artifact.deliver", artifactDeliverInputSchema);
  registerHubForwardingTool(server, "artifact_get", "Read a workflow artifact", "artifact.get", artifactGetInputSchema, true);
  registerHubForwardingTool(server, "board_patch", "Patch a workflow board", "board.patch", boardPatchInputSchema);
  registerHubForwardingTool(server, "board_get", "Read a workflow board", "board.get", boardGetInputSchema, true);
  registerHubForwardingTool(server, "human_request", "Request human input for a workflow run", "human.request", humanRequestInputSchema);
  registerHubForwardingTool(server, "human_answer", "Submit a human answer artifact for a workflow run", "human.answer", humanAnswerInputSchema);
  registerHubForwardingTool(server, "event_emit", "Emit a workflow event into the workflow log", "event.emit", eventEmitInputSchema);
  registerHubForwardingTool(server, "view_publish", "Publish workflow view data for the dashboard", "view.publish", viewPublishInputSchema);

  return server;
}

function registerDirectAgentTool(
  server: McpServer,
  service: HumanizeService,
  agent: AgentId,
  name: string,
  title: string
): void {
  server.registerTool(
    name,
    {
      title,
      description: `Run a single prompt through the ${agent} backend.`,
      inputSchema: directRunInputSchema,
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
      }
    },
    async (args) => jsonContent(await service.runAgent({ agent, ...args } satisfies AgentRequest & { agent: AgentId }))
  );
}

function messageOriginFromEnvironment(env: NodeJS.ProcessEnv): Record<string, unknown> {
  if (env.HUMANIZE2_RUN_ID === undefined || env.HUMANIZE2_RUN_ID.length === 0) {
    return {};
  }
  return {
    messageOrigin: {
      kind: "agent",
      sender: env.HUMANIZE2_RUN_SHORT_NAME ?? env.HUMANIZE2_RUN_ID,
      sourceRunId: env.HUMANIZE2_RUN_ID
    }
  };
}

function registerHubForwardingTool(
  server: McpServer,
  name: string,
  title: string,
  method: string,
  inputSchema: Record<string, z.ZodType>,
  readOnly = false
): void {
  server.registerTool(
    name,
    {
      title,
      description: `${title} through the local Humanize2 hub.`,
      inputSchema,
      annotations: {
        readOnlyHint: readOnly,
        destructiveHint: !readOnly,
        idempotentHint: readOnly,
        openWorldHint: false
      }
    },
    async (args) => jsonContent(await callHubRpc({
      url: process.env.HUMANIZE2_JSONRPC_URL ?? "http://127.0.0.1:4772/jsonrpc",
      method,
      params: args
    }))
  );
}

function jsonContent(value: unknown) {
  return {
    content: [
      {
        type: "text" as const,
        text: JSON.stringify(value, null, 2)
      }
    ]
  };
}
