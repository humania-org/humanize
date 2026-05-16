import { extractBackendSessionId, parseJsonLines } from "./json-lines.js";
import type { AgentBackend, AgentRequest, AgentResult, AgentStatus, CommandPlan, CommandRunner } from "./types.js";
import { environmentWithWorkflowContext, promptWithWorkflowContext } from "./workflow-context.js";

export function createClaudeBackend(runner: CommandRunner): AgentBackend {
  return {
    id: "claude",
    displayName: "Claude Code",
    async status(): Promise<AgentStatus> {
      const result = await runner.run({ command: "claude", args: ["--version"], timeoutMs: 5_000 });

      return {
        agent: "claude",
        displayName: "Claude Code",
        available: result.exitCode === 0,
        version: result.stdout.trim() || undefined,
        error: result.exitCode === 0 ? undefined : result.stderr.trim() || "claude is not available"
      };
    },
    async run(request: AgentRequest): Promise<AgentResult> {
      const plan = buildClaudePlan(request);
      const result = await runner.run(plan);
      const events = parseJsonLines(result.stdout);

      return {
        agent: "claude",
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

function buildClaudePlan(request: AgentRequest): CommandPlan {
  const args = ["-p", "--output-format", "stream-json", "--verbose"];

  if (request.resumeSessionId !== undefined) {
    args.push("--resume", request.resumeSessionId);
  }

  if (request.model !== undefined) {
    args.push("--model", request.model);
  }

  if (request.reasoningEffort !== undefined) {
    args.push("--effort", request.reasoningEffort);
  }

  if (request.permissionMode !== undefined) {
    args.push("--permission-mode", request.permissionMode);
  }

  if (request.extraArgs !== undefined) {
    args.push(...request.extraArgs);
  }

  args.push(promptWithWorkflowContext(request.prompt, request.workflowContext));

  return {
    command: "claude",
    args,
    cwd: request.cwd,
    env: environmentWithWorkflowContext(request.env, request.workflowContext),
    timeoutMs: request.timeoutMs,
    signal: request.signal,
    onOutput: request.onOutput
  };
}
