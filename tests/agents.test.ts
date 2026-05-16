import { describe, expect, it } from "vitest";

import { createCodexBackend } from "../src/agents/codex.js";
import { createClaudeBackend } from "../src/agents/claude.js";
import type { CommandPlan, CommandRunner } from "../src/agents/types.js";

function recordingRunner(recordedPlans: CommandPlan[]): CommandRunner {
  return {
    async run(plan) {
      recordedPlans.push(plan);
      return {
        exitCode: 0,
        signal: null,
        stdout: '{"type":"agent_message","message":"done"}\n',
        stderr: "",
        durationMs: 12,
        timedOut: false
      };
    }
  };
}

describe("CLI agent backends", () => {
  it("plans a non-interactive Codex command with JSON events", async () => {
    const plans: CommandPlan[] = [];
    const backend = createCodexBackend(recordingRunner(plans));

    const result = await backend.run({
      prompt: "Summarize the project",
      cwd: "/tmp/project",
      model: "gpt-5.2",
      sandbox: "workspace-write",
      timeoutMs: 1_000,
      extraArgs: ["--search"],
      env: { CODEX_API_KEY: "test-key" }
    });

    expect(plans).toHaveLength(1);
    expect(plans[0]).toMatchObject({
      command: "codex",
      cwd: "/tmp/project",
      timeoutMs: 1_000,
      env: { CODEX_API_KEY: "test-key" }
    });
    expect(plans[0].args).toEqual([
      "exec",
      "--json",
      "--cd",
      "/tmp/project",
      "--model",
      "gpt-5.2",
      "--sandbox",
      "workspace-write",
      "--search",
      "Summarize the project"
    ]);
    expect(result.success).toBe(true);
    expect(result.events).toEqual([{ type: "agent_message", message: "done" }]);
  });

  it("plans a Codex resume command when continuing a known backend session", async () => {
    const plans: CommandPlan[] = [];
    const backend = createCodexBackend(recordingRunner(plans));

    await backend.run({
      prompt: "Change direction",
      cwd: "/tmp/project",
      model: "gpt-5.2",
      timeoutMs: 1_000,
      resumeSessionId: "codex-session-a"
    });

    expect(plans[0].args).toEqual([
      "exec",
      "resume",
      "--json",
      "--model",
      "gpt-5.2",
      "codex-session-a",
      "Change direction"
    ]);
  });

  it("exposes workflow launch context to Codex through prompt text and environment variables", async () => {
    const plans: CommandPlan[] = [];
    const backend = createCodexBackend(recordingRunner(plans));

    await backend.run({
      prompt: "Do workflow work",
      cwd: "/tmp/project",
      timeoutMs: 1_000,
      env: { EXISTING: "1" },
      workflowContext: {
        workflowRunId: "workflow-run",
        vertexId: "builder",
        shortName: "builder",
        jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc",
        expectedArtifacts: [{ name: "result", schema: "result.v1" }],
        mcpToolNames: ["artifact_deliver", "workflow_get"]
      }
    });

    expect(plans[0].env).toMatchObject({
      EXISTING: "1",
      HUMANIZE2_WORKFLOW_RUN_ID: "workflow-run",
      HUMANIZE2_WORKFLOW_VERTEX_ID: "builder",
      HUMANIZE2_WORKFLOW_SHORT_NAME: "builder",
      HUMANIZE2_WORKFLOW_JSONRPC_URL: "http://127.0.0.1:4772/jsonrpc"
    });
    expect(plans[0].env?.HUMANIZE2_WORKFLOW_EXPECTED_ARTIFACTS).toContain("result");
    expect(plans[0].env?.HUMANIZE2_WORKFLOW_MCP_TOOLS).toContain("artifact_deliver");
    const prompt = plans[0].args[plans[0].args.length - 1];
    expect(prompt).toContain("Humanize2 workflow context");
    expect(prompt).toContain("workflow-run");
    expect(prompt).toContain("artifact_deliver");
    expect(prompt).toContain("Do not inspect, signal, attach to, or mutate the Humanize2 hub process");
    expect(prompt).toContain("Do workflow work");
  });

  it("plans a non-interactive Claude command with stream-json output", async () => {
    const plans: CommandPlan[] = [];
    const backend = createClaudeBackend(recordingRunner(plans));

    const result = await backend.run({
      prompt: "Explain the failing test",
      cwd: "/tmp/project",
      model: "sonnet",
      permissionMode: "acceptEdits",
      timeoutMs: 2_000,
      extraArgs: ["--brief"],
      env: { ANTHROPIC_API_KEY: "test-key" }
    });

    expect(plans).toHaveLength(1);
    expect(plans[0]).toMatchObject({
      command: "claude",
      cwd: "/tmp/project",
      timeoutMs: 2_000,
      env: { ANTHROPIC_API_KEY: "test-key" }
    });
    expect(plans[0].args).toEqual([
      "-p",
      "--output-format",
      "stream-json",
      "--verbose",
      "--model",
      "sonnet",
      "--permission-mode",
      "acceptEdits",
      "--brief",
      "Explain the failing test"
    ]);
    expect(result.success).toBe(true);
    expect(result.events).toEqual([{ type: "agent_message", message: "done" }]);
  });

  it("plans a Claude resume command when continuing a known backend session", async () => {
    const plans: CommandPlan[] = [];
    const backend = createClaudeBackend(recordingRunner(plans));

    await backend.run({
      prompt: "Change direction",
      cwd: "/tmp/project",
      model: "sonnet",
      permissionMode: "acceptEdits",
      timeoutMs: 2_000,
      resumeSessionId: "claude-session-a"
    });

    expect(plans[0].args).toEqual([
      "-p",
      "--output-format",
      "stream-json",
      "--verbose",
      "--resume",
      "claude-session-a",
      "--model",
      "sonnet",
      "--permission-mode",
      "acceptEdits",
      "Change direction"
    ]);
  });

  it("exposes workflow launch context to Claude through prompt text and environment variables", async () => {
    const plans: CommandPlan[] = [];
    const backend = createClaudeBackend(recordingRunner(plans));

    await backend.run({
      prompt: "Do workflow work",
      cwd: "/tmp/project",
      timeoutMs: 2_000,
      env: { EXISTING: "1" },
      workflowContext: {
        workflowRunId: "workflow-run",
        vertexId: "reviewer",
        shortName: "reviewer",
        jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc",
        expectedArtifacts: [{ name: "verdict", schema: "rlcr.verdict.v1" }],
        mcpToolNames: ["artifact_deliver", "workflow_get"]
      }
    });

    expect(plans[0].env).toMatchObject({
      EXISTING: "1",
      HUMANIZE2_WORKFLOW_RUN_ID: "workflow-run",
      HUMANIZE2_WORKFLOW_VERTEX_ID: "reviewer",
      HUMANIZE2_WORKFLOW_SHORT_NAME: "reviewer",
      HUMANIZE2_WORKFLOW_JSONRPC_URL: "http://127.0.0.1:4772/jsonrpc"
    });
    expect(plans[0].env?.HUMANIZE2_WORKFLOW_EXPECTED_ARTIFACTS).toContain("verdict");
    expect(plans[0].env?.HUMANIZE2_WORKFLOW_MCP_TOOLS).toContain("artifact_deliver");
    const prompt = plans[0].args[plans[0].args.length - 1];
    expect(prompt).toContain("Humanize2 workflow context");
    expect(prompt).toContain("workflow-run");
    expect(prompt).toContain("artifact_deliver");
    expect(prompt).toContain("Do not inspect, signal, attach to, or mutate the Humanize2 hub process");
    expect(prompt).toContain("Do workflow work");
  });
});
