import type { AgentBackend, AgentId, AgentRequest, AgentResult, AgentStatus } from "./types.js";

export function createFakeBackend(id: AgentId, response: string, delayMs = 0): AgentBackend {
  return {
    id,
    displayName: `${id} fake backend`,
    async status(): Promise<AgentStatus> {
      return {
        agent: id,
        displayName: `${id} fake backend`,
        available: true,
        version: "fake"
      };
    },
    async run(request: AgentRequest): Promise<AgentResult> {
      if (delayMs > 0) {
        await new Promise((resolve) => setTimeout(resolve, delayMs));
      }

      request.onOutput?.({ stream: "stdout", text: response });

      return {
        agent: id,
        success: true,
        exitCode: 0,
        signal: null,
        stdout: response,
        stderr: "",
        durationMs: 0,
        timedOut: false,
        command: id,
        args: [request.prompt],
        cwd: request.cwd,
        events: []
      };
    }
  };
}
