import { describe, expect, it } from "vitest";

import type { AgentBackend, AgentId, AgentRequest, AgentResult, AgentStatus } from "../src/agents/types.js";
import { AgentRunCoordinator } from "../src/hub/runs.js";
import { HumanizeService } from "../src/service.js";
import { WorkflowCoordinator } from "../src/workflows/coordinator.js";

describe("workflow manifest enforcement", () => {
  it("rejects cartridge load when an h2-agent uses an undeclared tool", async () => {
    const workflows = newCoordinator();
    await expect(workflows.loadHtml({
      html: `
        <h2-workflow id="undeclared-tool" name="undeclared-tool" version="0.1.0">
          <h2-manifest>
            <h2-capability name="agent" tools="claude"></h2-capability>
          </h2-manifest>
          <h2-template id="prompt">Do something.</h2-template>
          <h2-flow>
            <h2-agent id="worker" tool="codex" prompt="#prompt"></h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    })).rejects.toThrow(/manifest does not declare it|tool_undeclared/);
  });

  it("rejects cartridge load when an h2-script uses an undeclared adapter", async () => {
    const workflows = newCoordinator();
    await expect(workflows.loadHtml({
      html: `
        <h2-workflow id="undeclared-script" name="undeclared-script" version="0.1.0">
          <h2-manifest>
            <h2-capability name="script" allow="git.statusClean"></h2-capability>
          </h2-manifest>
          <h2-flow>
            <h2-script id="invoke" uses="git.detectBase"></h2-script>
          </h2-flow>
        </h2-workflow>
      `
    })).rejects.toThrow(/manifest does not declare it|script_undeclared/);
  });

  it("rejects cartridge load when a manifest-declared script adapter is not registered by the hub", async () => {
    const workflows = newCoordinator();
    await expect(workflows.loadHtml({
      html: `
        <h2-workflow id="unknown-script" name="unknown-script" version="0.1.0">
          <h2-manifest>
            <h2-capability name="script" allow="git.deleteEverything"></h2-capability>
          </h2-manifest>
          <h2-flow>
            <h2-script id="invoke" uses="git.deleteEverything"></h2-script>
          </h2-flow>
        </h2-workflow>
      `
    })).rejects.toThrow(/script_adapter_unknown|not registered/);
  });

  it("rejects cartridge load when an h2-agent uses a tool that is not authorized by the hub", async () => {
    const workflows = newCoordinator({ authorizedAgentTools: ["claude"] });
    await expect(workflows.loadHtml({
      html: `
        <h2-workflow id="unauthorized-tool" name="unauthorized-tool" version="0.1.0">
          <h2-manifest>
            <h2-capability name="agent" tools="claude,codex"></h2-capability>
          </h2-manifest>
          <h2-template id="prompt">Do something.</h2-template>
          <h2-flow>
            <h2-agent id="worker" tool="codex" prompt="#prompt"></h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    })).rejects.toThrow(/not authorized in the hub configuration|tool_unauthorized/);
  });

  it("emits manifest.warning.human_input_undeclared at load when h2-human is used without the manifest capability", async () => {
    const workflows = newCoordinator();
    const cartridge = await workflows.loadHtml({
      html: `
        <h2-workflow id="missing-human-capability" name="missing-human-capability" version="0.1.0">
          <h2-manifest></h2-manifest>
          <h2-flow>
            <h2-human id="ask" prompt="Confirm" artifact="answer"></h2-human>
          </h2-flow>
        </h2-workflow>
      `
    });
    expect(cartridge.loadEvents.map((event) => event.type)).toContain("manifest.warning.human_input_undeclared");
    const run = workflows.start({ cartridgeId: cartridge.id });
    expect(workflows.getRun(run.id).events.map((event) => event.type)).toContain("manifest.warning.human_input_undeclared");
  });
});

function newCoordinator(extras: { authorizedAgentTools?: string[] } = {}): WorkflowCoordinator {
  return new WorkflowCoordinator(emptyRunCoordinator(), {
    idFactory: ids(["workflow-run"]),
    now: fixedClock(),
    authorizedAgentTools: extras.authorizedAgentTools
  });
}

function emptyRunCoordinator(): AgentRunCoordinator {
  return new AgentRunCoordinator(new HumanizeService([
    fakeBackend("codex"),
    fakeBackend("claude")
  ]), {
    jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc"
  });
}

function fakeBackend(id: AgentId): AgentBackend {
  return {
    id,
    displayName: `${id} backend`,
    async status(): Promise<AgentStatus> {
      return { agent: id, displayName: `${id} backend`, available: true };
    },
    async run(_request: AgentRequest): Promise<AgentResult> {
      return {
        agent: id,
        success: true,
        exitCode: 0,
        signal: null,
        stdout: "",
        stderr: "",
        durationMs: 1,
        timedOut: false,
        command: id,
        args: [],
        cwd: process.cwd()
      };
    }
  };
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

function fixedClock(): () => string {
  let index = 0;
  return () => new Date(Date.UTC(2026, 4, 14, 22, 0, index++)).toISOString();
}
