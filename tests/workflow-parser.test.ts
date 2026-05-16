import { describe, expect, it } from "vitest";
import { readFile } from "node:fs/promises";

import { parseWorkflowCartridge } from "../src/workflows/parser.js";

describe("parseWorkflowCartridge", () => {
  it("parses an HTML workflow cartridge into executable nodes and safe view slots", () => {
    const cartridge = parseWorkflowCartridge({
      sourcePath: "flow/experimental/team-intervention-smoke/workflow.html",
      html: `
        <h2-workflow id="team-intervention-smoke" name="Team Intervention Smoke" version="0.1.0" schema="humanize2.workflow.html.v1">
          <h2-manifest>
            <h2-capability name="agent" tools="codex,claude"></h2-capability>
          </h2-manifest>
          <h2-state>
            <h2-board id="team-board" schema="team.board.v1"></h2-board>
          </h2-state>
          <h2-template id="captain-prompt" type="prompt">Create three workers through Humanize2.</h2-template>
          <h2-template id="worker-1-prompt" type="prompt">Initial task A.</h2-template>
          <h2-template id="worker-1-change" type="message">Change to task D.</h2-template>
          <h2-flow>
            <h2-script id="preflight" uses="test.pass"></h2-script>
            <h2-agent id="captain" tool="codex" role="captain" prompt="#captain-prompt" short-name="captain"></h2-agent>
            <h2-parallel id="workers">
              <h2-agent id="worker-1" parent="captain" tool="claude" prompt="#worker-1-prompt" short-name="worker-1-a"></h2-agent>
            </h2-parallel>
            <h2-sleep id="brief-wait" duration-ms="25"></h2-sleep>
            <h2-message id="redirect-worker-1" target="worker-1" prompt="#worker-1-change" short-name="worker-1-d"></h2-message>
            <h2-await id="worker-1-final-wait" on="exists(artifact.worker-1-final)"></h2-await>
            <h2-branch id="result-branch" on="artifact.worker-1-final.status">
              <h2-case value="ok" goto="finished"></h2-case>
              <h2-default goto="finished"></h2-default>
            </h2-branch>
            <h2-script id="finished" uses="test.pass"></h2-script>
          </h2-flow>
          <h2-view slot="properties">
            <h2-widget ref="team-board"></h2-widget>
          </h2-view>
        </h2-workflow>
      `
    });

    expect(cartridge).toMatchObject({
      id: "team-intervention-smoke",
      name: "Team Intervention Smoke",
      version: "0.1.0",
      schema: "humanize2.workflow.html.v1",
      sourcePath: "flow/experimental/team-intervention-smoke/workflow.html",
      boards: [{ id: "team-board", schema: "team.board.v1" }],
      templates: {
        "captain-prompt": "Create three workers through Humanize2.",
        "worker-1-prompt": "Initial task A.",
        "worker-1-change": "Change to task D."
      },
      views: [{ slot: "properties" }]
    });
    expect(cartridge.nodes).toMatchObject([
      { type: "script", id: "preflight", uses: "test.pass" },
      { type: "agent", id: "captain", tool: "codex", promptRef: "captain-prompt", shortName: "captain" },
      {
        type: "parallel",
        id: "workers",
        children: [
          { type: "agent", id: "worker-1", parent: "captain", tool: "claude", promptRef: "worker-1-prompt" }
        ]
      },
      { type: "sleep", id: "brief-wait", durationMs: 25 },
      { type: "message", id: "redirect-worker-1", target: "worker-1", promptRef: "worker-1-change" },
      { type: "await", id: "worker-1-final-wait", on: "exists(artifact.worker-1-final)" },
      {
        type: "branch",
        id: "result-branch",
        on: "artifact.worker-1-final.status",
        cases: [
          { value: "ok", goto: "finished" }
        ],
        defaultTarget: "finished"
      },
      { type: "script", id: "finished", uses: "test.pass" }
    ]);
  });

  it("rejects cartridges that put h2-expect outside h2-agent", () => {
    expect(() => parseWorkflowCartridge({
      html: `
        <h2-workflow id="bad-expect" name="Bad Expect" version="0.1.0">
          <h2-flow>
            <h2-expect artifact="anything"></h2-expect>
          </h2-flow>
        </h2-workflow>
      `
    })).toThrow(/expect_outside_agent|h2-expect must be a direct child of h2-agent/);
  });

  it("parses agent input references", () => {
    const cartridge = parseWorkflowCartridge({
      html: `
        <h2-workflow id="agent-inputs" name="Agent Inputs" version="0.1.0">
          <h2-flow>
            <h2-agent id="builder" tool="codex" prompt="Do work">
              <h2-input artifact="review-verdict" schema="rlcr.verdict.v1" label="Latest review" optional="true"></h2-input>
              <h2-input board="loop-status" label="Loop status"></h2-input>
            </h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    });

    expect((cartridge.nodes[0] as any).inputs).toEqual([
      {
        kind: "artifact",
        name: "review-verdict",
        schema: "rlcr.verdict.v1",
        label: "Latest review",
        optional: true
      },
      {
        kind: "board",
        id: "loop-status",
        label: "Loop status",
        optional: false
      }
    ]);
  });

  it("rejects h2-input outside h2-agent", () => {
    expect(() => parseWorkflowCartridge({
      html: `
        <h2-workflow id="bad-input" name="Bad Input" version="0.1.0">
          <h2-flow>
            <h2-input artifact="review-verdict"></h2-input>
          </h2-flow>
        </h2-workflow>
      `
    })).toThrow(/input_outside_agent|h2-input must be a direct child of h2-agent/);
  });

  it("rejects branches missing h2-default", () => {
    expect(() => parseWorkflowCartridge({
      html: `
        <h2-workflow id="bad-branch" name="Bad Branch" version="0.1.0">
          <h2-flow>
            <h2-script id="target" uses="test.pass"></h2-script>
            <h2-branch on="artifact.x.status"><h2-case value="ok" goto="target"></h2-case></h2-branch>
          </h2-flow>
        </h2-workflow>
      `
    })).toThrow(/branch_missing_default|h2-default/);
  });

  it("rejects cartridges without one h2-workflow root", () => {
    expect(() => parseWorkflowCartridge({ html: "<main></main>" })).toThrow(/h2-workflow/);
  });

  it("parses control and coordination primitives needed by first-party cartridges", () => {
    const cartridge = parseWorkflowCartridge({
      html: `
        <h2-workflow id="control-flow" name="Control Flow" version="0.1.0">
          <h2-flow>
            <h2-check id="clean-worktree" uses="git.statusClean"></h2-check>
            <h2-human id="plan-quiz" prompt="Confirm plan understanding" artifact="quiz-answer"></h2-human>
            <h2-loop id="review-loop" max="2" while="not exists(artifact.final-verdict)" counter-label="Round">
              <h2-script id="loop-script" uses="test.pass"></h2-script>
            </h2-loop>
            <h2-transform id="prepare-review" from="artifact.round-summary" to="board.goal-tracker"></h2-transform>
          </h2-flow>
        </h2-workflow>
      `
    });

    expect(cartridge.nodes).toMatchObject([
      { type: "check", id: "clean-worktree", uses: "git.statusClean" },
      { type: "human", id: "plan-quiz", promptText: "Confirm plan understanding", artifact: "quiz-answer" },
      {
        type: "loop",
        id: "review-loop",
        max: 2,
        while: "not exists(artifact.final-verdict)",
        counterLabel: "Round",
        children: [{ type: "script", id: "loop-script", uses: "test.pass" }]
      },
      { type: "transform", id: "prepare-review", from: "artifact.round-summary", to: "board.goal-tracker" }
    ]);
  });

  it("parses state event and artifact declarations plus agent hooks explicitly", () => {
    const cartridge = parseWorkflowCartridge({
      html: `
        <h2-workflow id="declarations" name="Declarations" version="0.1.0">
          <h2-state>
            <h2-event type="worker.done"></h2-event>
            <h2-artifact name="result" schema="result.v1"></h2-artifact>
          </h2-state>
          <h2-template id="prompt">Deliver the result.</h2-template>
          <h2-flow>
            <h2-agent id="worker" tool="codex" prompt="#prompt">
              <h2-hook kind="soft" on="before-exit" artifact="result" schema="result.v1"></h2-hook>
            </h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    });

    expect((cartridge as any).eventTypes).toEqual([{ type: "worker.done" }]);
    expect((cartridge as any).artifactTypes).toEqual([{ name: "result", schema: "result.v1" }]);
    expect((cartridge.nodes[0] as any).hooks).toEqual([
      { kind: "soft", on: "before-exit", artifact: "result", schema: "result.v1" }
    ]);
  });

  it("records a warning when a hard hook is declared because v0.1 downgrades it to soft enforcement", () => {
    const cartridge = parseWorkflowCartridge({
      html: `
        <h2-workflow id="hard-hook" name="Hard Hook" version="0.1.0">
          <h2-template id="prompt">Deliver the result.</h2-template>
          <h2-flow>
            <h2-agent id="worker" tool="codex" prompt="#prompt">
              <h2-hook kind="hard" on="before-exit" artifact="result"></h2-hook>
            </h2-agent>
          </h2-flow>
        </h2-workflow>
      `
    });

    expect(cartridge.loadEvents.map((event) => event.type)).toContain("hook.unsupported");
    expect((cartridge.nodes[0] as any).hooks).toEqual([
      { kind: "soft", on: "before-exit", artifact: "result" }
    ]);
  });

  it("rejects h2-hook outside h2-agent instead of silently ignoring it", () => {
    expect(() => parseWorkflowCartridge({
      html: `
        <h2-workflow id="bad-hook" name="Bad Hook" version="0.1.0">
          <h2-flow>
            <h2-hook kind="soft" on="before-exit"></h2-hook>
          </h2-flow>
        </h2-workflow>
      `
    })).toThrow(/hook_outside_agent|h2-hook must be a direct child of h2-agent/);
  });

  it("rejects unknown executable h2 elements instead of skipping them", () => {
    expect(() => parseWorkflowCartridge({
      html: `
        <h2-workflow id="unknown-element" name="Unknown Element" version="0.1.0">
          <h2-flow>
            <h2-launch-rockets id="bad"></h2-launch-rockets>
          </h2-flow>
        </h2-workflow>
      `
    })).toThrow(/unknown_element|h2-launch-rockets/);
  });

  it("parses the bundled experimental team intervention smoke cartridge", async () => {
    const sourcePath = "flow/experimental/team-intervention-smoke/workflow.html";
    const html = await readFile(sourcePath, "utf8");

    const cartridge = parseWorkflowCartridge({ html, sourcePath });

    expect(cartridge).toMatchObject({
      id: "team-intervention-smoke",
      sourcePath
    });
    expect(flatNodeTypes(cartridge.nodes)).not.toContain("parallel");
    expect(flatNodeTypes(cartridge.nodes)).not.toContain("message");
    expect(flatNodeIds(cartridge.nodes)).toContain("complete");
    expect(cartridge.nodes.filter((node) => node.type === "await")).toHaveLength(0);
    const captainAgents = flattenNodes(cartridge.nodes).filter((node) =>
      node.type === "agent" && node.id === "captain"
    );
    expect(captainAgents).toHaveLength(1);
    expect(captainAgents.map((node) => node.type === "agent" ? node.expects : [])).toEqual([
      [{ artifact: "team-summary", schema: "team.captainResult.v1" }]
    ]);
    const workerAgents = flattenNodes(cartridge.nodes).filter((node) =>
      node.type === "agent" && typeof node.id === "string" && node.id.startsWith("worker-")
    );
    expect(workerAgents).toHaveLength(0);
  });

  it("parses the bundled first-party Humanize1-style cartridges", async () => {
    const flowIds = ["gen-idea", "gen-plan", "refine-plan", "rlcr"];
    const cartridges = await Promise.all(flowIds.map(async (flowId) => {
      const sourcePath = `flow/${flowId}/workflow.html`;
      const html = await readFile(sourcePath, "utf8");
      return parseWorkflowCartridge({ html, sourcePath });
    }));

    expect(cartridges.map((cartridge) => cartridge.id)).toEqual(flowIds);
    expect(flatNodeTypes(cartridges.find((cartridge) => cartridge.id === "gen-idea")?.nodes ?? [])).toEqual(expect.arrayContaining([
      "check",
      "parallel",
      "agent",
      "await"
    ]));
    expect(flatNodeTypes(cartridges.find((cartridge) => cartridge.id === "gen-plan")?.nodes ?? [])).toEqual(expect.arrayContaining([
      "check",
      "agent",
      "await",
      "branch"
    ]));
    expect(flatNodeTypes(cartridges.find((cartridge) => cartridge.id === "refine-plan")?.nodes ?? [])).toEqual(expect.arrayContaining([
      "check",
      "transform",
      "agent",
      "await"
    ]));
    expect(flatNodeTypes(cartridges.find((cartridge) => cartridge.id === "rlcr")?.nodes ?? [])).toEqual(expect.arrayContaining([
      "check",
      "human",
      "loop",
      "agent",
      "branch"
    ]));
  });
});

describe("parseWorkflowCartridge rejects event.<type> outside h2-await on", () => {
  it("rejects h2-branch on=\"event.<type>\"", () => {
    expect(() => parseWorkflowCartridge({
      html: `
        <h2-workflow id="bad-event-branch-parser" name="Bad Event Branch" version="0.1.0">
          <h2-flow>
            <h2-script id="left" uses="test.pass"></h2-script>
            <h2-branch on="event.[custom.done]">
              <h2-case value="x" goto="left"></h2-case>
              <h2-default goto="left"></h2-default>
            </h2-branch>
          </h2-flow>
        </h2-workflow>
      `
    })).toThrow(/event_root_outside_await|event\.<type>/);
  });

  it("rejects h2-loop while=\"event.<type>\"", () => {
    expect(() => parseWorkflowCartridge({
      html: `
        <h2-workflow id="bad-event-loop-parser" name="Bad Event Loop" version="0.1.0">
          <h2-flow>
            <h2-loop id="bad" max="1" while="event.go">
              <h2-script id="body" uses="test.pass"></h2-script>
            </h2-loop>
          </h2-flow>
        </h2-workflow>
      `
    })).toThrow(/event_root_outside_await|event\.<type>/);
  });

  it("accepts h2-await on=\"event.<type>\"", () => {
    expect(() => parseWorkflowCartridge({
      html: `
        <h2-workflow id="ok-event-await-parser" name="OK Event Await" version="0.1.0">
          <h2-flow>
            <h2-await id="wait" on="event.[custom.done]"></h2-await>
          </h2-flow>
        </h2-workflow>
      `
    })).not.toThrow();
  });
});

interface NodeLike {
  type?: string;
  id?: string;
  children?: unknown;
  expects?: unknown;
}

function flatNodeTypes(nodes: NodeLike[]): string[] {
  return nodes.flatMap((node) => [
    ...(node.type === undefined ? [] : [node.type]),
    ...(Array.isArray(node.children) ? flatNodeTypes(node.children as NodeLike[]) : [])
  ]);
}

function flatNodeIds(nodes: NodeLike[]): string[] {
  return nodes.flatMap((node) => [
    ...(node.id === undefined ? [] : [node.id]),
    ...(Array.isArray(node.children) ? flatNodeIds(node.children as NodeLike[]) : [])
  ]);
}

function flattenNodes(nodes: NodeLike[]): NodeLike[] {
  return nodes.flatMap((node) => [
    node,
    ...(Array.isArray(node.children) ? flattenNodes(node.children as NodeLike[]) : [])
  ]);
}
