import { readFile } from "node:fs/promises";

import { describe, expect, it } from "vitest";

import type { AgentBackend, AgentId, AgentRequest, AgentResult, AgentStatus } from "../src/agents/types.js";
import { AgentRunCoordinator } from "../src/hub/runs.js";
import { HumanizeService } from "../src/service.js";
import { WorkflowCoordinator } from "../src/workflows/coordinator.js";
import { buildWorkflowProjection } from "../src/workflows/projection.js";
import { initializeRlcrGoalTrackerBoard } from "../src/workflows/rlcr-board.js";
import type { GraphInstance, WorkflowCartridge, WorkflowFlowProjectionNode, WorkflowRunRecord } from "../src/workflows/types.js";

describe("workflow dashboard projections", () => {
  it("initializes the RLCR goal tracker from markdown implementation plans", () => {
    const value = `# Note Graph Explorer Implementation Plan

## Goal

Implement a Node.js / TypeScript CLI named \`note-graph\` that scans Markdown notes and reports wiki-link graph information.

## Required Tests

- Parser tests cover titles and wiki links.
- Graph tests cover incoming and missing links.

## Completion Criteria

- package setup exists;
- parser, graph, formatter, and CLI behavior are implemented;
- npm test passes;
- npm run typecheck passes;
`;

    const board = initializeRlcrGoalTrackerBoard(value, {
      cwd: undefined,
      graph: graphWithLoop(),
      run: runWithLoopIteration()
    });

    expect(board).toMatchObject({
      ultimateGoal: "Implement a Node.js / TypeScript CLI named `note-graph` that scans Markdown notes and reports wiki-link graph information.",
      planSummary: "Implement a Node.js / TypeScript CLI named `note-graph` that scans Markdown notes and reports wiki-link graph information.",
      acceptanceCriteriaCount: 4,
      activeTaskCount: 2,
      acceptanceCriteria: [
        "package setup exists;",
        "parser, graph, formatter, and CLI behavior are implemented;",
        "npm test passes;",
        "npm run typecheck passes;"
      ],
      activeTasks: [
        "Parser tests cover titles and wiki links.",
        "Graph tests cover incoming and missing links."
      ]
    });
  });

  it("projects RLCR as a loop-centered flow for the dashboard", async () => {
    const runs = new AgentRunCoordinator(new HumanizeService([
      delayedBackend("codex"),
      delayedBackend("claude")
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc",
      idFactory: ids([
        "agent-plan-compliance",
        "agent-plan-quiz",
        "agent-builder",
        "agent-reviewer"
      ])
    });
    const workflows = new WorkflowCoordinator(runs, {
      idFactory: ids([
        "workflow-run",
        "artifact-implementation-plan",
        "artifact-plan-compliance",
        "artifact-plan-quiz",
        "artifact-plan-answer",
        "artifact-round-summary",
        "artifact-review-verdict"
      ]),
      now: fixedClock()
    });
    const html = await readFile("flow/rlcr/workflow.html", "utf8");
    await workflows.loadHtml({ html, sourcePath: "flow/rlcr/workflow.html" });
    const run = workflows.start({ cartridgeId: "rlcr" });

    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "implementation-plan",
      schema: "rlcr.plan.v1",
      producer: "human",
      content: {
        goal: "Add projection-aware dashboard rendering.",
        acceptanceCriteria: ["Flow view shows the RLCR loop."],
        tasks: ["Implement projection data."]
      }
    });
    await waitForAgentStarted(workflows, run.id, "plan-compliance-checker");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-compliance",
      schema: "rlcr.planCompliance.v1",
      producer: "plan-compliance-checker",
      content: { status: "pass" }
    });
    await waitForAgentStarted(workflows, run.id, "plan-quiz-generator");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-quiz",
      schema: "rlcr.quiz.v1",
      producer: "plan-quiz-generator",
      content: { questions: [] }
    });
    await waitUntil(() => workflows.getRun(run.id).waitingFor.some((target) =>
      target.kind === "human" && target.artifact === "plan-quiz-answer"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-quiz-answer",
      schema: "rlcr.quizAnswer.v1",
      producer: "human",
      content: { confirmed: true }
    });
    await waitForAgentStarted(workflows, run.id, "builder");

    const projected = workflows.listRunsWithRenderedViews()[0];
    const flow = projected.projection?.flow;
    expect(flow).toBeDefined();
    expect(flow?.nodes.map((node) => node.id)).toEqual(expect.arrayContaining([
      "clean-worktree",
      "base-detection",
      "plan-await",
      "code-review-loop",
      "finalizer",
      "complete-end",
      "stopped"
    ]));

    const codeReviewLoop = findProjectionNode(flow!.nodes, "code-review-loop");
    expect(codeReviewLoop).toMatchObject({
      id: "code-review-loop",
      kind: "loop",
      status: "running",
      loop: {
        max: 42,
        iteration: 1,
        counterLabel: "Review Round"
      }
    });
    expect(codeReviewLoop?.children?.some((node) => node.kind === "loop" && node.id === "implementation-loop")).toBe(true);
    expect(codeReviewLoop?.children?.some((node) => node.kind === "agent" && node.id === "code-review")).toBe(true);
    expect(codeReviewLoop?.children?.some((node) => node.kind === "branch" && node.id === "code-review-route")).toBe(true);

    const loop = findProjectionNode(flow!.nodes, "implementation-loop");
    expect(loop).toMatchObject({
      id: "implementation-loop",
      kind: "loop",
      status: "running",
      loop: {
        max: 42,
        iteration: 1,
        counterLabel: "Round"
      }
    });
    expect(findProjectionNode(loop!.children ?? [], "builder")).toMatchObject({
      id: "builder",
      kind: "agent",
      agent: {
        role: "builder",
        tool: "claude",
        inputs: expect.arrayContaining([
          expect.objectContaining({ kind: "artifact", name: "implementation-plan", schema: "rlcr.plan.v1" }),
          expect.objectContaining({ kind: "artifact", name: "review-verdict", schema: "rlcr.verdict.v1", optional: true }),
          expect.objectContaining({ kind: "artifact", name: "code-review-result", schema: "rlcr.codeReview.v1", optional: true }),
          expect.objectContaining({ kind: "board", id: "goal-tracker" }),
          expect.objectContaining({ kind: "board", id: "loop-status", optional: true })
        ])
      }
    });
    expect(findProjectionNode(loop!.children ?? [], "reviewer")).toMatchObject({
      id: "reviewer",
      kind: "agent",
      agent: {
        role: "reviewer",
        tool: "codex",
        inputs: expect.arrayContaining([
          expect.objectContaining({ kind: "artifact", name: "round-summary", schema: "rlcr.summary.v1" }),
          expect.objectContaining({ kind: "board", id: "goal-tracker" })
        ])
      }
    });
    expect(findProjectionNode(loop!.children ?? [], "review-route")).toMatchObject({
      id: "review-route",
      kind: "branch",
      branch: {
        on: "artifact.review-verdict.status",
        cases: expect.arrayContaining([
          { value: "revise", continueLoop: "implementation-loop" },
          { value: "complete", goto: "code-review" }
        ])
      }
    });
    expect(findProjectionNode(flow!.nodes, "code-review")).toMatchObject({
      id: "code-review",
      kind: "agent",
      agent: {
        tool: "codex",
        role: "reviewer",
        shortName: "rlcr-code-review",
        inputs: expect.arrayContaining([
          expect.objectContaining({ kind: "artifact", name: "round-summary", schema: "rlcr.summary.v1" }),
          expect.objectContaining({ kind: "artifact", name: "review-verdict", schema: "rlcr.verdict.v1" })
        ])
      }
    });
    expect(findProjectionNode(flow!.nodes, "code-review-route")).toMatchObject({
      id: "code-review-route",
      kind: "branch",
      branch: {
        on: "artifact.code-review-result.status",
        cases: expect.arrayContaining([
          { value: "revise", continueLoop: "code-review-loop" },
          { value: "complete", goto: "finalizer" }
        ])
      }
    });

    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "round-summary",
      schema: "rlcr.summary.v1",
      producer: "builder",
      content: { status: "stopped-for-test" }
    });
    await waitForAgentStarted(workflows, run.id, "reviewer");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "review-verdict",
      schema: "rlcr.verdict.v1",
      producer: "reviewer",
      content: { status: "stop" }
    });
    await workflows.waitForRun(run.id, 1_000);
  });

  it("initializes the RLCR goal tracker and renders the operational panel", async () => {
    const runs = new AgentRunCoordinator(new HumanizeService([
      delayedBackend("codex"),
      delayedBackend("claude")
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc",
      idFactory: ids([
        "agent-plan-compliance",
        "agent-plan-quiz",
        "agent-builder",
        "agent-reviewer"
      ])
    });
    const workflows = new WorkflowCoordinator(runs, {
      idFactory: ids([
        "workflow-run",
        "artifact-implementation-plan",
        "artifact-plan-compliance",
        "artifact-plan-quiz",
        "artifact-plan-answer",
        "artifact-round-summary",
        "artifact-review-verdict"
      ]),
      now: fixedClock()
    });
    const html = await readFile("flow/rlcr/workflow.html", "utf8");
    await workflows.loadHtml({ html, sourcePath: "flow/rlcr/workflow.html" });
    const run = workflows.start({ cartridgeId: "rlcr" });

    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "implementation-plan",
      schema: "rlcr.plan.v1",
      producer: "human",
      content: {
        goal: "Add projection-aware dashboard rendering.",
        acceptanceCriteria: [
          "Flow View shows the loop.",
          "Chat View shows the builder/reviewer exchange.",
          "Workflow-specific Views show the operational panel."
        ],
        tasks: ["Implement projection data.", "Render the RLCR monitor."]
      }
    });
    await waitForAgentStarted(workflows, run.id, "plan-compliance-checker");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-compliance",
      schema: "rlcr.planCompliance.v1",
      producer: "plan-compliance-checker",
      content: { status: "pass" }
    });
    await waitForAgentStarted(workflows, run.id, "plan-quiz-generator");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-quiz",
      schema: "rlcr.quiz.v1",
      producer: "plan-quiz-generator",
      content: { questions: [] }
    });
    await waitUntil(() => workflows.getRun(run.id).waitingFor.some((target) =>
      target.kind === "human" && target.artifact === "plan-quiz-answer"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-quiz-answer",
      schema: "rlcr.quizAnswer.v1",
      producer: "human",
      content: { confirmed: true }
    });
    await waitForAgentStarted(workflows, run.id, "builder");

    const projected = workflows.listRunsWithRenderedViews()[0];
    const goalTracker = projected.boards.find((board) => board.id === "goal-tracker")?.value;
    expect(goalTracker).toMatchObject({
      stage: "implementation",
      phase: "build",
      round: 1,
      maxRounds: 42,
      ultimateGoal: "Add projection-aware dashboard rendering.",
      planSummary: "Add projection-aware dashboard rendering.",
      acceptanceCriteriaCount: 3,
      activeTaskCount: 2,
      completedTaskCount: 0,
      deferredTaskCount: 0,
      blockingIssueCount: 0,
      queuedIssueCount: 0,
      nextAction: "Await reviewer verdict"
    });

    const propertiesHtml = projected.views.find((view) => view.slot === "properties")?.html;
    expect(propertiesHtml).toContain("RLCR Status");
    expect(propertiesHtml).toContain("Round");
    expect(propertiesHtml).toContain("Acceptance criteria");
    expect(propertiesHtml).toContain("Operational");
    expect(propertiesHtml).toContain("Await reviewer verdict");
    expect(propertiesHtml).toContain("Add projection-aware dashboard rendering.");

    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "round-summary",
      schema: "rlcr.summary.v1",
      producer: "builder",
      content: { status: "stopped-for-test" }
    });
    await waitForAgentStarted(workflows, run.id, "reviewer");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "review-verdict",
      schema: "rlcr.verdict.v1",
      producer: "reviewer",
      content: { status: "stop", findings: ["Stop requested by test."] }
    });
    const finished = await workflows.waitForRun(run.id, 1_000);
    const finishedLoopStatus = finished.boards.find((board) => board.id === "loop-status")?.value;
    expect(finishedLoopStatus).toMatchObject({
      status: "stop",
      round: 1,
      phase: "stopped",
      nextAction: "Stop workflow",
      reviewSummary: "Stop requested by test."
    });
  });

  it("projects failed workflow nodes and failed loops distinctly", () => {
    const projection = buildWorkflowProjection(
      {
        id: "rlcr-lite",
        name: "RLCR Lite",
        sourceHtml: "",
        manifest: {
          agentTools: [],
          scriptAllowlist: [],
          artifactSchemas: [],
          declaresView: true,
          declaresHumanInput: true
        },
        boards: [],
        eventTypes: [],
        artifactTypes: [],
        templates: {},
        vars: [],
        views: [],
        nodes: [
          {
            type: "loop",
            id: "implementation-loop",
            max: 42,
            children: [
              {
                type: "agent",
                id: "reviewer",
                tool: "codex",
                inputs: [],
                expects: [],
                hooks: []
              }
            ]
          }
        ],
        loadEvents: []
      } as WorkflowCartridge,
      {} as GraphInstance,
      {
        id: "workflow-run",
        cartridgeId: "rlcr-lite",
        cartridgeName: "RLCR Lite",
        status: "failed",
        createdAt: fixedClock()(),
        waitingFor: [],
        nodeRunIds: {
          reviewer: "reviewer-run"
        },
        boards: [],
        artifacts: [],
        views: [],
        events: [
          {
            index: 0,
            timestamp: fixedClock()(),
            type: "vertex.started",
            data: { vertexId: "implementation-loop", kind: "loop-entry" }
          },
          {
            index: 1,
            timestamp: fixedClock()(),
            type: "loop.iteration_started",
            data: { loopId: "implementation-loop", iteration: 1 }
          },
          {
            index: 2,
            timestamp: fixedClock()(),
            type: "vertex.completed",
            data: { vertexId: "implementation-loop", kind: "loop-entry" }
          },
          {
            index: 3,
            timestamp: fixedClock()(),
            type: "vertex.started",
            data: { vertexId: "reviewer", kind: "agent" }
          },
          {
            index: 4,
            timestamp: fixedClock()(),
            type: "vertex.failed",
            data: { vertexId: "reviewer", reason: "agent.terminal_failure" }
          }
        ],
        loopIterations: {
          "implementation-loop": 1
        },
        vars: {}
      } as WorkflowRunRecord
    );

    const loop = findProjectionNode(projection.flow.nodes, "implementation-loop");
    expect(loop).toMatchObject({
      status: "failed"
    });
    expect(findProjectionNode(loop?.children ?? [], "reviewer")).toMatchObject({
      status: "failed"
    });
  });
});

function delayedBackend(id: AgentId): AgentBackend {
  return {
    id,
    displayName: `${id} test backend`,
    async status(): Promise<AgentStatus> {
      return {
        agent: id,
        displayName: `${id} test backend`,
        available: true,
        version: `${id}-test`
      };
    },
    async run(request: AgentRequest): Promise<AgentResult> {
      await new Promise((resolve) => setTimeout(resolve, 40));
      return {
        agent: id,
        success: true,
        exitCode: 0,
        signal: null,
        stdout: `handled ${request.prompt}`,
        stderr: "",
        durationMs: 40,
        timedOut: false,
        command: id,
        args: [request.prompt],
        cwd: request.cwd
      };
    }
  };
}

async function waitForAgentStarted(workflows: WorkflowCoordinator, workflowRunId: string, nodeId: string): Promise<void> {
  await waitUntil(() => workflows.getRun(workflowRunId).events.some((event) =>
    event.type === "agent.started" &&
    (event.data as { nodeId?: string }).nodeId === nodeId
  ));
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt > 1_500) {
      throw new Error("timed out waiting for test condition");
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

function fixedClock(): () => string {
  return () => "2026-05-15T00:00:00.000Z";
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

function findProjectionNode(nodes: WorkflowFlowProjectionNode[], id: string): WorkflowFlowProjectionNode | undefined {
  for (const node of nodes) {
    if (node.id === id) {
      return node;
    }
    const found = findProjectionNode(node.children ?? [], id);
    if (found !== undefined) {
      return found;
    }
  }
  return undefined;
}

function graphWithLoop(): GraphInstance {
  return {
    vertices: new Map(),
    edges: new Map(),
    outgoing: new Map(),
    incoming: new Map(),
    startVertexId: "start",
    endVertexId: "end",
    loops: new Map([
      [
        "implementation-loop",
        {
          loopVertexId: "implementation-loop",
          entryVertexId: "builder",
          tailVertexId: "review-route",
          bodyVertexIds: ["builder", "reviewer", "update-loop-status", "review-route"],
          max: 42
        }
      ]
    ])
  };
}

function runWithLoopIteration(): WorkflowRunRecord {
  return {
    id: "workflow-run",
    cartridgeId: "rlcr",
    cartridgeName: "RLCR",
    status: "running",
    createdAt: fixedClock()(),
    waitingFor: [],
    nodeRunIds: {},
    boards: [],
    artifacts: [],
    views: [],
    events: [],
    loopIterations: {
      "implementation-loop": 1
    },
    vars: {}
  };
}
