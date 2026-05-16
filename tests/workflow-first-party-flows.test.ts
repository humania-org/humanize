import { readFile } from "node:fs/promises";

import { describe, expect, it } from "vitest";

import type { AgentBackend, AgentId, AgentRequest, AgentResult, AgentStatus } from "../src/agents/types.js";
import { AgentRunCoordinator } from "../src/hub/runs.js";
import { HumanizeService } from "../src/service.js";
import { WorkflowCoordinator } from "../src/workflows/coordinator.js";
import type { WorkflowAgentNode, WorkflowBranchNode, WorkflowCartridge, WorkflowLoopNode, WorkflowNode } from "../src/workflows/types.js";

describe("first-party flow behavior", () => {
  it("gen-idea preserves the directed-diversity exploration shape", async () => {
    const workflows = newCoordinator();
    const html = await readFile("flow/gen-idea/workflow.html", "utf8");
    const cartridge = await workflows.loadHtml({ html, sourcePath: "flow/gen-idea/workflow.html" });
    const agents = agentNodes(cartridge);
    const explorers = agents.filter((agent) => agent.role === "explorer");

    expect(explorers).toHaveLength(6);
    expect(explorers.map((agent) => agent.id)).toEqual([
      "explore-direction-1",
      "explore-direction-2",
      "explore-direction-3",
      "explore-direction-4",
      "explore-direction-5",
      "explore-direction-6"
    ]);
    expect(template(cartridge, "direction-prompt")).toContain("exactly 6 orthogonal directions");
    expect(template(cartridge, "exploration-prompt")).toContain("OBJECTIVE_EVIDENCE");
    expect(template(cartridge, "exploration-prompt")).toContain("Read-only");
    expect(template(cartridge, "synthesis-prompt")).toContain("Primary direction");
    expect(template(cartridge, "synthesis-prompt")).toContain("alternatives");
  });

  it("gen-plan models first-pass analysis and bounded convergence before final planning", async () => {
    const workflows = newCoordinator();
    const html = await readFile("flow/gen-plan/workflow.html", "utf8");
    const cartridge = await workflows.loadHtml({ html, sourcePath: "flow/gen-plan/workflow.html" });
    const agents = agentNodes(cartridge);
    const loop = loopNode(cartridge, "plan-convergence-loop");
    const branch = branchNode(cartridge, "convergence-route");

    expect(agents.map((agent) => agent.id)).toEqual(expect.arrayContaining([
      "relevance-checker",
      "first-pass-reviewer",
      "candidate-writer",
      "convergence-reviewer",
      "final-plan-writer"
    ]));
    expect(loop.max).toBe(3);
    expect(loop.children.some((node) => node.type === "agent" && node.id === "candidate-writer")).toBe(true);
    expect(loop.children.some((node) => node.type === "agent" && node.id === "convergence-reviewer")).toBe(true);
    expect(branch.cases).toContainEqual({ value: "revise", continueLoop: "plan-convergence-loop" });
    expect(branch.cases).toContainEqual({ value: "converged", goto: "final-plan-writer" });
    expect(branch.defaultTarget).toBe("decision-request");
    expect(template(cartridge, "final-plan-prompt")).toContain("Task Breakdown");
    expect(template(cartridge, "final-plan-prompt")).toContain("coding");
    expect(template(cartridge, "final-plan-prompt")).toContain("analyze");
    expect(template(cartridge, "final-plan-prompt")).toContain("Pending User Decisions");
  });

  it("rlcr models preflight gates, understanding quiz, loop review, and finalization", async () => {
    const workflows = newCoordinator();
    const html = await readFile("flow/rlcr/workflow.html", "utf8");
    const cartridge = await workflows.loadHtml({ html, sourcePath: "flow/rlcr/workflow.html" });
    const agents = agentNodes(cartridge);
    const loop = loopNode(cartridge, "implementation-loop");
    const codeReviewLoop = loopNode(cartridge, "code-review-loop");
    const branch = branchNode(cartridge, "review-route");
    const codeReviewBranch = branchNode(cartridge, "code-review-route");

    expect(agents.map((agent) => agent.id)).toEqual(expect.arrayContaining([
      "plan-compliance-checker",
      "plan-quiz-generator",
      "builder",
      "reviewer",
      "code-review",
      "finalizer"
    ]));
    expect(loop.max).toBe(42);
    expect(branch.cases).toContainEqual({ value: "revise", continueLoop: "implementation-loop" });
    expect(branch.cases).toContainEqual({ value: "complete", goto: "code-review" });
    expect(codeReviewLoop.max).toBe(42);
    expect(codeReviewLoop.children.some((node) => node.type === "loop" && node.id === "implementation-loop")).toBe(true);
    expect(codeReviewLoop.children.some((node) => node.type === "agent" && node.id === "code-review")).toBe(true);
    expect(codeReviewLoop.children.some((node) => node.type === "branch" && node.id === "code-review-route")).toBe(true);
    expect(codeReviewBranch.cases).toContainEqual({ value: "revise", continueLoop: "code-review-loop" });
    expect(codeReviewBranch.cases).toContainEqual({ value: "complete", goto: "finalizer" });
    expect(template(cartridge, "builder-prompt")).toContain("goal tracker");
    expect(template(cartridge, "builder-prompt")).toContain("summary");
    expect(template(cartridge, "reviewer-prompt")).toContain("COMPLETE");
    expect(template(cartridge, "finalizer-prompt")).toContain("Finalize");
  });

  it("workflow start can override first-party agent backend per run", async () => {
    const seenAgents: AgentId[] = [];
    const workflows = new WorkflowCoordinator(new AgentRunCoordinator(new HumanizeService([
      slowBackend("codex", seenAgents),
      slowBackend("claude", seenAgents)
    ]), {
      jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc"
    }), {
      idFactory: makeIdFactory(),
      now: fixedClock(),
      authorizedScripts: () => true
    });
    const html = await readFile("flow/gen-idea/workflow.html", "utf8");
    await workflows.loadHtml({ html, sourcePath: "flow/gen-idea/workflow.html" });
    const run = workflows.start({ cartridgeId: "gen-idea", agentToolOverride: "codex" });

    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "idea-input",
      schema: "idea.input.v1",
      producer: "human",
      content: { topic: "x" }
    });
    await waitForAgent(workflows, run.id, "direction-lead");
    expect(seenAgents).toEqual(["codex"]);
  });

  it("gen-plan happy path with converged verdict reaches plan-final via final-plan-writer", async () => {
    const workflows = newCoordinator();
    const html = await readFile("flow/gen-plan/workflow.html", "utf8");
    await workflows.loadHtml({ html, sourcePath: "flow/gen-plan/workflow.html" });
    const run = workflows.start({ cartridgeId: "gen-plan" });

    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-draft",
      schema: "plan.draft.v1",
      producer: "human",
      content: { summary: "draft" }
    });
    await waitForAgent(workflows, run.id, "relevance-checker");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-relevance",
      schema: "plan.relevance.v1",
      producer: "relevance-checker",
      content: { status: "relevant" }
    });
    await waitForAgent(workflows, run.id, "first-pass-reviewer");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-first-pass-analysis",
      schema: "plan.analysis.v1",
      producer: "first-pass-reviewer",
      content: { risks: [] }
    });
    await waitForAgent(workflows, run.id, "candidate-writer");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-candidate",
      schema: "plan.candidate.v1",
      producer: "candidate-writer",
      content: { steps: ["a"] }
    });
    await waitForAgent(workflows, run.id, "convergence-reviewer");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-convergence-verdict",
      schema: "plan.verdict.v1",
      producer: "convergence-reviewer",
      content: { status: "converged" }
    });
    await waitForAgent(workflows, run.id, "final-plan-writer");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-final",
      schema: "plan.final.v1",
      producer: "final-plan-writer",
      content: { steps: ["a"] }
    });
    const finished = await workflows.waitForRun(run.id, 3_000);
    expect(finished.status).toBe("succeeded");
    expect(finished.waitingFor).toEqual([]);
    const verticesCompleted = finished.events
      .filter((event) => event.type === "vertex.completed")
      .map((event) => (event.data as { vertexId?: string }).vertexId);
    expect(verticesCompleted).toEqual(expect.arrayContaining([
      "relevance-checker",
      "first-pass-reviewer",
      "candidate-writer",
      "convergence-reviewer",
      "final-plan-writer"
    ]));
    expect(verticesCompleted).not.toContain("decision-request");
    expect(finished.artifacts.find((artifact) => artifact.name === "plan-final")).toBeDefined();
  });

  it("gen-plan needs-human-decision path routes through decision-request then final-plan-writer", async () => {
    const workflows = newCoordinator();
    const html = await readFile("flow/gen-plan/workflow.html", "utf8");
    await workflows.loadHtml({ html, sourcePath: "flow/gen-plan/workflow.html" });
    const run = workflows.start({ cartridgeId: "gen-plan" });

    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-draft",
      schema: "plan.draft.v1",
      producer: "human",
      content: { summary: "draft" }
    });
    await waitForAgent(workflows, run.id, "relevance-checker");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-relevance",
      schema: "plan.relevance.v1",
      producer: "relevance-checker",
      content: { status: "relevant" }
    });
    await waitForAgent(workflows, run.id, "first-pass-reviewer");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-first-pass-analysis",
      schema: "plan.analysis.v1",
      producer: "first-pass-reviewer",
      content: { risks: [] }
    });
    await waitForAgent(workflows, run.id, "candidate-writer");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-candidate",
      schema: "plan.candidate.v1",
      producer: "candidate-writer",
      content: { steps: ["a"] }
    });
    await waitForAgent(workflows, run.id, "convergence-reviewer");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-convergence-verdict",
      schema: "plan.verdict.v1",
      producer: "convergence-reviewer",
      content: { status: "needs-human-decision" }
    });
    await waitUntil(() => workflows.getRun(run.id).waitingFor.some((target) =>
      target.kind === "human" && target.artifact === "plan-human-decision"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-human-decision",
      schema: "plan.humanDecision.v1",
      producer: "human",
      content: { decision: "go" }
    });
    await waitForAgent(workflows, run.id, "final-plan-writer");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "plan-final",
      schema: "plan.final.v1",
      producer: "final-plan-writer",
      content: { steps: ["b"] }
    });
    const finished = await workflows.waitForRun(run.id, 3_000);
    expect(finished.status).toBe("succeeded");
    expect(finished.waitingFor).toEqual([]);
    const verticesCompleted = finished.events
      .filter((event) => event.type === "vertex.completed")
      .map((event) => (event.data as { vertexId?: string }).vertexId);
    expect(verticesCompleted).toEqual(expect.arrayContaining([
      "convergence-reviewer",
      "decision-request",
      "final-plan-writer"
    ]));
  });

  it("gen-idea fires direction lead, six explorers in parallel, and synthesis lead", async () => {
    const workflows = newCoordinator();
    const html = await readFile("flow/gen-idea/workflow.html", "utf8");
    await workflows.loadHtml({ html, sourcePath: "flow/gen-idea/workflow.html" });
    const run = workflows.start({ cartridgeId: "gen-idea" });

    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "idea-input",
      schema: "idea.input.v1",
      producer: "human",
      content: { topic: "x" }
    });
    await waitForAgent(workflows, run.id, "direction-lead");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "idea-directions",
      schema: "idea.directions.v1",
      producer: "direction-lead",
      content: { directions: ["a", "b", "c", "d", "e", "f"] }
    });
    for (let index = 1; index <= 6; index++) {
      await waitForAgent(workflows, run.id, `explore-direction-${index}`);
    }
    for (let index = 1; index <= 6; index++) {
      workflows.deliverArtifact({
        workflowRunId: run.id,
        name: `idea-proposal-${index}`,
        schema: "idea.proposal.v1",
        producer: `explore-direction-${index}`,
        content: { evidence: [] }
      });
    }
    await waitForAgent(workflows, run.id, "synthesis-lead");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "idea-draft",
      schema: "idea.draft.v1",
      producer: "synthesis-lead",
      content: { primary: "a" }
    });
    const finished = await workflows.waitForRun(run.id, 3_000);
    expect(finished.status).toBe("succeeded");
    expect(finished.waitingFor).toEqual([]);
    const verticesCompleted = finished.events
      .filter((event) => event.type === "vertex.completed")
      .map((event) => (event.data as { vertexId?: string }).vertexId);
    expect(verticesCompleted).toEqual(expect.arrayContaining([
      "direction-lead",
      "explore-direction-1",
      "explore-direction-2",
      "explore-direction-3",
      "explore-direction-4",
      "explore-direction-5",
      "explore-direction-6",
      "synthesis-lead"
    ]));
    expect(finished.artifacts.find((artifact) => artifact.name === "idea-draft")).toBeDefined();
  });

  it("refine-plan processes comments, takes the human decision, and delivers refined-plan plus refinement-qa", async () => {
    const workflows = newCoordinator();
    const html = await readFile("flow/refine-plan/workflow.html", "utf8");
    await workflows.loadHtml({ html, sourcePath: "flow/refine-plan/workflow.html" });
    const run = workflows.start({ cartridgeId: "refine-plan" });

    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "annotated-plan",
      schema: "plan.annotated.v1",
      producer: "human",
      content: { comments: [{ ref: "abc", body: "fix" }] }
    });
    await waitForAgent(workflows, run.id, "comment-processor");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "comment-processing-result",
      schema: "plan.comments.v1",
      producer: "comment-processor",
      content: { resolved: 1, unresolved: 0 }
    });
    await waitUntil(() => workflows.getRun(run.id).waitingFor.some((target) =>
      target.kind === "human" && target.artifact === "comment-human-decision"
    ));
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "comment-human-decision",
      schema: "plan.humanDecision.v1",
      producer: "human",
      content: { decision: "go" }
    });
    await waitForAgent(workflows, run.id, "refinement-writer");
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "refined-plan",
      schema: "plan.refined.v1",
      producer: "refinement-writer",
      content: { steps: ["a"] }
    });
    workflows.deliverArtifact({
      workflowRunId: run.id,
      name: "refinement-qa",
      schema: "plan.qa.v1",
      producer: "refinement-writer",
      content: { ok: true }
    });
    const finished = await workflows.waitForRun(run.id, 3_000);
    expect(finished.status).toBe("succeeded");
    expect(finished.waitingFor).toEqual([]);
    const verticesCompleted = finished.events
      .filter((event) => event.type === "vertex.completed")
      .map((event) => (event.data as { vertexId?: string }).vertexId);
    expect(verticesCompleted).toEqual(expect.arrayContaining([
      "comment-processor",
      "unresolved-comment-decision",
      "refinement-writer"
    ]));
    expect(finished.artifacts.find((artifact) => artifact.name === "refined-plan")).toBeDefined();
    expect(finished.artifacts.find((artifact) => artifact.name === "refinement-qa")).toBeDefined();
  });
});

function agentNodes(cartridge: WorkflowCartridge): WorkflowAgentNode[] {
  return allNodes(cartridge).filter((node): node is WorkflowAgentNode => node.type === "agent");
}

function loopNode(cartridge: WorkflowCartridge, id: string): WorkflowLoopNode {
  const node = allNodes(cartridge).find((candidate): candidate is WorkflowLoopNode =>
    candidate.type === "loop" && candidate.id === id
  );
  if (node === undefined) {
    throw new Error(`missing loop node ${id}`);
  }
  return node;
}

function branchNode(cartridge: WorkflowCartridge, id: string): WorkflowBranchNode {
  const node = allNodes(cartridge).find((candidate): candidate is WorkflowBranchNode =>
    candidate.type === "branch" && candidate.id === id
  );
  if (node === undefined) {
    throw new Error(`missing branch node ${id}`);
  }
  return node;
}

function template(cartridge: WorkflowCartridge, id: string): string {
  const value = cartridge.templates[id];
  if (value === undefined) {
    throw new Error(`missing template ${id}`);
  }
  return value;
}

function allNodes(cartridge: WorkflowCartridge): WorkflowNode[] {
  const result: WorkflowNode[] = [];
  const visit = (node: WorkflowNode): void => {
    result.push(node);
    if ("children" in node) {
      for (const child of node.children) {
        visit(child);
      }
    }
  };
  for (const node of cartridge.nodes) {
    visit(node);
  }
  return result;
}

function newCoordinator(): WorkflowCoordinator {
  return new WorkflowCoordinator(emptyRunCoordinator(), {
    idFactory: makeIdFactory(),
    now: fixedClock(),
    authorizedScripts: () => true
  });
}

function emptyRunCoordinator(): AgentRunCoordinator {
  return new AgentRunCoordinator(new HumanizeService([
    slowBackend("codex"),
    slowBackend("claude")
  ]), {
    jsonRpcUrl: "http://127.0.0.1:4772/jsonrpc"
  });
}

function slowBackend(id: AgentId, seenAgents: AgentId[] = []): AgentBackend {
  return {
    id,
    displayName: `${id} backend`,
    async status(): Promise<AgentStatus> {
      return { agent: id, displayName: `${id} backend`, available: true };
    },
    async run(request: AgentRequest): Promise<AgentResult> {
      seenAgents.push(id);
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, 80);
        request.signal?.addEventListener("abort", () => {
          clearTimeout(timer);
          resolve();
        }, { once: true });
      });
      return {
        agent: id,
        success: true,
        exitCode: 0,
        signal: null,
        stdout: `handled ${request.prompt}`,
        stderr: "",
        durationMs: 80,
        timedOut: false,
        command: id,
        args: [request.prompt],
        cwd: request.cwd
      };
    }
  };
}

function makeIdFactory(): () => string {
  let n = 0;
  return () => `id-${++n}`;
}

function fixedClock(): () => string {
  let index = 0;
  return () => new Date(Date.UTC(2026, 4, 14, 23, 30, index++)).toISOString();
}

async function waitForAgent(workflows: WorkflowCoordinator, runId: string, nodeId: string): Promise<void> {
  await waitUntil(() => workflows.getRun(runId).events.some((event) =>
    event.type === "agent.started" &&
    (event.data as { nodeId?: string }).nodeId === nodeId
  ));
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt > 3_000) {
      throw new Error("timed out waiting for test condition");
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
