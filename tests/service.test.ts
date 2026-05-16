import { describe, expect, it } from "vitest";

import { NodeCommandRunner } from "../src/agents/cli.js";
import type { AgentBackend, AgentRequest, AgentResult, AgentStatus } from "../src/agents/types.js";
import { HumanizeService } from "../src/service.js";

function fakeBackend(id: "codex" | "claude"): AgentBackend {
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

describe("HumanizeService", () => {
  it("dispatches agent_run requests to the selected backend", async () => {
    const service = new HumanizeService([fakeBackend("codex"), fakeBackend("claude")]);

    const result = await service.runAgent({
      agent: "claude",
      prompt: "write docs",
      cwd: "/tmp/project"
    });

    expect(result.agent).toBe("claude");
    expect(result.stdout).toBe("handled write docs");
    expect(result.cwd).toBe("/tmp/project");
  });

  it("reports all backend statuses when no agent is selected", async () => {
    const service = new HumanizeService([fakeBackend("codex"), fakeBackend("claude")]);

    const status = await service.agentStatus({});

    expect(status.agents.map((agent) => agent.agent)).toEqual(["codex", "claude"]);
    expect(status.agents.every((agent) => agent.available)).toBe(true);
  });

  it("rejects unknown agents with a clear error", async () => {
    const service = new HumanizeService([fakeBackend("codex")]);

    await expect(
      service.runAgent({
        agent: "claude",
        prompt: "hello"
      })
    ).rejects.toThrow("Unknown agent: claude");
  });
});

describe("NodeCommandRunner", () => {
  it("captures stdout, stderr, exit status, and duration", async () => {
    const runner = new NodeCommandRunner();

    const result = await runner.run({
      command: process.execPath,
      args: ["-e", "console.log('out'); console.error('err')"],
      timeoutMs: 5_000
    });

    expect(result.exitCode).toBe(0);
    expect(result.signal).toBeNull();
    expect(result.stdout.trim()).toBe("out");
    expect(result.stderr.trim()).toBe("err");
    expect(result.durationMs).toBeGreaterThanOrEqual(0);
    expect(result.timedOut).toBe(false);
  });

  it("streams stdout and stderr chunks while commands are running", async () => {
    const runner = new NodeCommandRunner();
    const outputEvents: Array<{ stream: string; text: string }> = [];

    const result = await runner.run({
      command: process.execPath,
      args: ["-e", "process.stdout.write('out-chunk'); process.stderr.write('err-chunk')"],
      timeoutMs: 5_000,
      onOutput: (event) => outputEvents.push({ stream: event.stream, text: event.text })
    });

    expect(result.exitCode).toBe(0);
    expect(outputEvents).toEqual([
      { stream: "stdout", text: "out-chunk" },
      { stream: "stderr", text: "err-chunk" }
    ]);
  });

  it("kills commands that exceed their timeout", async () => {
    const runner = new NodeCommandRunner();

    const result = await runner.run({
      command: process.execPath,
      args: ["-e", "setTimeout(() => {}, 10_000)"],
      timeoutMs: 50
    });

    expect(result.exitCode).toBeNull();
    expect(result.timedOut).toBe(true);
  });
});
