import { extractBackendSessionId, parseJsonLines } from "./json-lines.js";
import type { AgentBackend, AgentRequest, AgentResult, AgentStatus, CommandPlan, CommandRunner } from "./types.js";
import { environmentWithWorkflowContext, promptWithWorkflowContext } from "./workflow-context.js";

export function createCodexBackend(runner: CommandRunner): AgentBackend {
  return {
    id: "codex",
    displayName: "Codex CLI",
    async status(): Promise<AgentStatus> {
      const result = await runner.run({ command: "codex", args: ["--version"], timeoutMs: 5_000 });

      return {
        agent: "codex",
        displayName: "Codex CLI",
        available: result.exitCode === 0,
        version: result.stdout.trim() || undefined,
        error: result.exitCode === 0 ? undefined : result.stderr.trim() || "codex is not available"
      };
    },
    async run(request: AgentRequest): Promise<AgentResult> {
      const plan = buildCodexPlan(request);
      const result = await runner.run(plan);
      const events = parseJsonLines(result.stdout);

      return {
        agent: "codex",
        success: result.exitCode === 0 && !result.timedOut,
        exitCode: result.exitCode,
        signal: result.signal,
        stdout: result.stdout,
        stderr: result.stderr,
        durationMs: result.durationMs,
        timedOut: result.timedOut,
        command: plan.command,
        args: plan.args,
        cwd: plan.cwd,
        backendSessionId: extractBackendSessionId(events),
        events
      };
    }
  };
}

function buildCodexPlan(request: AgentRequest): CommandPlan {
  const args = request.resumeSessionId === undefined
    ? ["exec", "--json"]
    : ["exec", "resume", "--json"];

  if (request.resumeSessionId === undefined && request.cwd !== undefined) {
    args.push("--cd", request.cwd);
  }

  if (request.model !== undefined) {
    args.push("--model", request.model);
  }

  if (request.reasoningEffort !== undefined) {
    args.push("-c", `model_reasoning_effort="${request.reasoningEffort}"`);
  }

  if (request.resumeSessionId === undefined && request.sandbox !== undefined) {
    args.push("--sandbox", request.sandbox);
  }

  if (request.extraArgs !== undefined) {
    args.push(...request.extraArgs);
  }

  if (request.resumeSessionId !== undefined) {
    args.push(request.resumeSessionId);
  }

  args.push(promptWithWorkflowContext(request.prompt, request.workflowContext));

  return {
    command: "codex",
    args,
    cwd: request.cwd,
    env: environmentWithWorkflowContext(request.env, request.workflowContext),
    timeoutMs: request.timeoutMs,
    signal: request.signal,
    onOutput: request.onOutput
  };
}
