import { execFileSync } from "node:child_process";

import type { GraphInstance, WorkflowRunRecord } from "./types.js";

export interface RlcrBoardContext {
  cwd?: string;
  graph: GraphInstance;
  run: WorkflowRunRecord;
  loopId?: string;
}

export function initializeRlcrGoalTrackerBoard(value: unknown, context: RlcrBoardContext): Record<string, unknown> {
  const plan = normalizePlan(value);
  const loopMeta = primaryLoop(context.graph);
  const round = currentRound(context.run, loopMeta?.loopVertexId);
  const goal = firstString(
    plan.goal,
    plan.ultimateGoal,
    plan.summary,
    firstArrayItem(plan.steps),
    firstArrayItem(plan.tasks),
    "RLCR implementation"
  );
  const planSummary = firstString(plan.summary, plan.goal, goal);
  const acceptanceCriteria = asArray(plan.acceptanceCriteria ?? plan.ac ?? plan.criteria);
  const activeTasks = asArray(plan.tasks ?? plan.activeTasks ?? plan.steps);
  const completedTasks = asArray(plan.completedTasks);
  const deferredTasks = asArray(plan.deferredTasks ?? plan.deferred);
  const blockingIssues = asArray(plan.blockingIssues ?? plan.blockers);
  const queuedIssues = asArray(plan.queuedIssues ?? plan.queue);
  const gitSummary = summarizeGitStatus(context.cwd);

  return {
    stage: "implementation",
    phase: "build",
    round,
    maxRounds: loopMeta?.max ?? 1,
    ultimateGoal: goal,
    planSummary,
    acceptanceCriteriaCount: acceptanceCriteria.length,
    activeTaskCount: activeTasks.length,
    completedTaskCount: completedTasks.length,
    deferredTaskCount: deferredTasks.length,
    blockingIssueCount: blockingIssues.length,
    queuedIssueCount: queuedIssues.length,
    gitSummary,
    nextAction: "Await reviewer verdict",
    acceptanceCriteria,
    activeTasks,
    completedTasks,
    deferredTasks,
    blockingIssues,
    queuedIssues
  };
}

function normalizePlan(value: unknown): Record<string, unknown> {
  if (typeof value === "string") {
    return parseMarkdownPlan(value);
  }
  return asRecord(value);
}

function parseMarkdownPlan(markdown: string): Record<string, unknown> {
  const sections = markdownSections(markdown);
  const goal = firstMarkdownParagraph(
    sections.get("goal"),
    sections.get("goal description"),
    sections.get("objective"),
    sections.get("purpose")
  );
  const summary = firstMarkdownParagraph(
    sections.get("summary"),
    sections.get("overview"),
    goal
  );
  const acceptanceCriteria = firstNonEmptyList(
    markdownListItems(sections.get("acceptance criteria")),
    markdownListItems(sections.get("completion criteria")),
    markdownListItems(sections.get("success criteria"))
  );
  const tasks = firstNonEmptyList(
    markdownListItems(sections.get("tasks")),
    markdownListItems(sections.get("work items")),
    markdownListItems(sections.get("required tests")),
    markdownListItems(sections.get("implementation plan"))
  );

  return {
    goal,
    summary,
    acceptanceCriteria,
    tasks
  };
}

function markdownSections(markdown: string): Map<string, string[]> {
  const sections = new Map<string, string[]>();
  let current = "";
  let inFence = false;
  sections.set(current, []);

  for (const rawLine of markdown.split(/\r?\n/)) {
    const line = rawLine.trimEnd();
    if (/^\s*```/.test(line)) {
      inFence = !inFence;
      sections.get(current)!.push(line);
      continue;
    }
    if (!inFence) {
      const heading = /^#{1,6}\s+(.+?)\s*$/.exec(line);
      if (heading !== null) {
        current = normalizeHeading(heading[1]);
        if (!sections.has(current)) {
          sections.set(current, []);
        }
        continue;
      }
    }
    sections.get(current)!.push(line);
  }

  return sections;
}

function normalizeHeading(value: string): string {
  return value
    .replace(/[`*_]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function firstMarkdownParagraph(...values: unknown[]): string | undefined {
  for (const value of values) {
    if (typeof value === "string" && value.trim().length > 0) {
      return value.trim();
    }
    if (!Array.isArray(value)) {
      continue;
    }
    const paragraph: string[] = [];
    let inFence = false;
    for (const rawLine of value) {
      const line = String(rawLine).trim();
      if (/^```/.test(line)) {
        inFence = !inFence;
        continue;
      }
      if (inFence || line.length === 0) {
        if (paragraph.length > 0) {
          break;
        }
        continue;
      }
      if (/^[-*]\s+/.test(line) || /^\d+[.)]\s+/.test(line)) {
        if (paragraph.length > 0) {
          break;
        }
        continue;
      }
      paragraph.push(line);
    }
    if (paragraph.length > 0) {
      return paragraph.join(" ").trim();
    }
  }
  return undefined;
}

function markdownListItems(lines: string[] | undefined): string[] {
  if (lines === undefined) {
    return [];
  }
  const items: string[] = [];
  let inFence = false;
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (/^```/.test(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) {
      continue;
    }
    const item = /^[-*]\s+(.+)$/.exec(line) ?? /^\d+[.)]\s+(.+)$/.exec(line);
    if (item !== null) {
      items.push(item[1].trim());
    }
  }
  return items;
}

function firstNonEmptyList(...values: string[][]): string[] {
  return values.find((value) => value.length > 0) ?? [];
}

export function updateRlcrLoopStatusBoard(value: unknown, context: RlcrBoardContext): Record<string, unknown> {
  const verdict = asRecord(value);
  const loopMeta = primaryLoop(context.graph);
  const loopId = context.loopId ?? loopMeta?.loopVertexId;
  const round = currentRound(context.run, loopId);
  const status = firstString(verdict.status, "stop");
  const phase = status === "revise" ? "build" : (status === "complete" ? "review" : "stopped");
  const nextAction = status === "revise"
    ? "Return to builder"
    : (status === "complete" ? "Await code review" : "Stop workflow");
  const reviewSummary = summarizeText(
    verdict.reviewSummary,
    verdict.summary,
    verdict.reason,
    verdict.findings,
    verdict.requiredFollowUp,
    status
  );

  return {
    status,
    phase,
    round,
    nextAction,
    reviewSummary,
    findings: asArray(verdict.findings),
    requiredFollowUp: asArray(verdict.requiredFollowUp),
    statusLabel: status
  };
}

function primaryLoop(graph: GraphInstance): { loopVertexId: string; max: number } | undefined {
  const first = graph.loops.values().next();
  if (first.done) {
    return undefined;
  }
  return {
    loopVertexId: first.value.loopVertexId,
    max: first.value.max
  };
}

function currentRound(run: WorkflowRunRecord, loopId: string | undefined): number {
  if (loopId === undefined) {
    return 1;
  }
  const value = run.loopIterations[loopId];
  return Number.isFinite(value) && value > 0 ? value : 1;
}

function summarizeGitStatus(cwd: string | undefined): string {
  if (cwd === undefined || cwd.length === 0) {
    return "not available";
  }

  try {
    const porcelain = execFileSync("git", ["status", "--porcelain=v1", "--untracked-files=all"], {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 2_000
    }).trim();
    if (porcelain.length === 0) {
      return "clean";
    }

    const lines = porcelain.split("\n");
    const modified = lines.filter((line) => line.startsWith(" M") || line.startsWith("MM") || line.startsWith("AM") || line.startsWith(" T")).length;
    const added = lines.filter((line) => line.startsWith("A ") || line.startsWith("AA") || line.startsWith("AM")).length;
    const deleted = lines.filter((line) => line.startsWith(" D") || line.startsWith("DD")).length;
    const untracked = lines.filter((line) => line.startsWith("??")).length;
    const diffStat = execFileSync("git", ["diff", "--shortstat"], {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 2_000
    }).trim();
    const statSuffix = diffStat.length > 0 ? ` ${diffStat}` : "";
    return `~${modified} +${added} -${deleted} ?${untracked}${statSuffix}`.trim();
  } catch {
    return "not available";
  }
}

function asRecord(value: unknown): Record<string, unknown> {
  if (value === undefined || value === null || typeof value !== "object" || Array.isArray(value)) {
    return {};
  }
  return value as Record<string, unknown>;
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function firstArrayItem(value: unknown): string | undefined {
  if (!Array.isArray(value) || value.length === 0) {
    return undefined;
  }
  const first = value[0];
  return typeof first === "string" ? first : undefined;
}

function firstString(...values: unknown[]): string {
  for (const value of values) {
    if (typeof value === "string" && value.trim().length > 0) {
      return value.trim();
    }
  }
  return "RLCR implementation";
}

function summarizeText(...values: unknown[]): string {
  for (const value of values) {
    if (typeof value === "string" && value.trim().length > 0) {
      return value.trim();
    }
    if (Array.isArray(value) && value.length > 0) {
      const strings = value.filter((item) => typeof item === "string").map((item) => String(item).trim()).filter((item) => item.length > 0);
      if (strings.length > 0) {
        return strings.join("; ");
      }
    }
  }
  return "No review summary";
}
