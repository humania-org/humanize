import type { AgentBackend, AgentId, AgentRequest, AgentResult, AgentStatus } from "./agents/types.js";
import { DEFAULT_RUN_TIMEOUT_MS } from "./config.js";

export interface RunAgentInput extends AgentRequest {
  agent: AgentId;
  shortName?: string;
}

export interface AgentStatusInput {
  agent?: AgentId;
}

export interface AgentStatusResult {
  agents: AgentStatus[];
}

export class HumanizeService {
  private readonly backends: Map<AgentId, AgentBackend>;

  constructor(backends: AgentBackend[]) {
    this.backends = new Map(backends.map((backend) => [backend.id, backend]));
  }

  async runAgent(input: RunAgentInput): Promise<AgentResult> {
    const backend = this.backends.get(input.agent);

    if (backend === undefined) {
      throw new Error(`Unknown agent: ${input.agent}`);
    }

    const { agent: _agent, shortName: _shortName, ...request } = input;
    return backend.run({
      ...request,
      timeoutMs: request.timeoutMs ?? DEFAULT_RUN_TIMEOUT_MS
    });
  }

  async agentStatus(input: AgentStatusInput): Promise<AgentStatusResult> {
    const backends = input.agent === undefined
      ? [...this.backends.values()]
      : [this.requireBackend(input.agent)];

    const agents = await Promise.all(backends.map((backend) => backend.status()));
    return { agents };
  }

  private requireBackend(agent: AgentId): AgentBackend {
    const backend = this.backends.get(agent);

    if (backend === undefined) {
      throw new Error(`Unknown agent: ${agent}`);
    }

    return backend;
  }
}
