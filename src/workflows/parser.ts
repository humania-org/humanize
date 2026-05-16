import { parseFragment, serializeOuter, type DefaultTreeAdapterTypes } from "parse5";

import type {
  WorkflowAgentNode,
  WorkflowAgentInput,
  WorkflowArtifactDefinition,
  WorkflowAwaitNode,
  WorkflowBoardDefinition,
  WorkflowBranchNode,
  WorkflowCartridge,
  WorkflowCase,
  WorkflowEventDefinition,
  WorkflowEventRecord,
  WorkflowExpectation,
  WorkflowHookDefinition,
  WorkflowHumanNode,
  WorkflowManifest,
  WorkflowMessageNode,
  WorkflowNode,
  WorkflowVarDefinition,
  WorkflowViewDefinition
} from "./types.js";

type Element = DefaultTreeAdapterTypes.Element;
type ChildNode = DefaultTreeAdapterTypes.ChildNode;
type ParentNode = DefaultTreeAdapterTypes.ParentNode;

export class CartridgeParseError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
    this.name = "CartridgeParseError";
  }
}

export interface ParseWorkflowCartridgeInput {
  html: string;
  sourcePath?: string;
}

export function parseWorkflowCartridge(input: ParseWorkflowCartridgeInput): WorkflowCartridge {
  const fragment = parseFragment(input.html);
  const roots = findElements(fragment, "h2-workflow");
  if (roots.length !== 1) {
    throw new CartridgeParseError(
      "cartridge.invalid_root",
      "workflow cartridge must contain exactly one h2-workflow root"
    );
  }

  const root = roots[0];
  const id = requiredAttr(root, "id", "h2-workflow");
  const flow = directChild(root, "h2-flow");
  if (flow === undefined) {
    throw new CartridgeParseError("cartridge.missing_flow", `h2-workflow ${id} must contain h2-flow`);
  }

  validateExpectPlacement(root);
  validateHookPlacement(root);
  validateInputPlacement(root);

  const manifest = parseManifest(root);
  const views = parseViews(root);
  const nodes = parseNodeChildren(flow);
  const loadEvents = collectLoadEvents(manifest, root, views, nodes);

  return {
    id,
    name: attr(root, "name") ?? id,
    version: attr(root, "version"),
    schema: attr(root, "schema"),
    sourceHtml: input.html,
    sourcePath: input.sourcePath,
    manifest,
    boards: parseBoards(root),
    eventTypes: parseEventTypes(root),
    artifactTypes: parseArtifactTypes(root),
    templates: parseTemplates(root),
    vars: parseVars(root),
    views,
    nodes,
    loadEvents
  };
}

function parseManifest(root: Element): WorkflowManifest {
  const manifestEl = directChild(root, "h2-manifest");
  if (manifestEl === undefined) {
    return {
      agentTools: [],
      scriptAllowlist: [],
      artifactSchemas: [],
      declaresView: false,
      declaresHumanInput: false
    };
  }
  const capabilities = directChildren(manifestEl, "h2-capability");
  const manifest: WorkflowManifest = {
    agentTools: [],
    scriptAllowlist: [],
    artifactSchemas: [],
    declaresView: false,
    declaresHumanInput: false
  };
  for (const capability of capabilities) {
    const name = attr(capability, "name");
    if (name === undefined) {
      continue;
    }
    if (name === "agent") {
      manifest.agentTools = parseCommaList(attr(capability, "tools"));
    } else if (name === "script") {
      manifest.scriptAllowlist = parseCommaList(attr(capability, "allow"));
    } else if (name === "artifact") {
      manifest.artifactSchemas = parseCommaList(attr(capability, "schemas"));
    } else if (name === "view") {
      manifest.declaresView = true;
    } else if (name === "human-input") {
      manifest.declaresHumanInput = true;
    }
  }
  return manifest;
}

function parseCommaList(value: string | undefined): string[] {
  if (value === undefined) {
    return [];
  }
  return value
    .split(",")
    .map((item) => item.trim())
    .filter((item) => item.length > 0);
}

function parseVars(root: Element): WorkflowVarDefinition[] {
  return findElements(root, "h2-var").map((element) => ({
    name: requiredAttr(element, "name", "h2-var"),
    value: attr(element, "value") ?? ""
  }));
}

function validateExpectPlacement(root: Element): void {
  const allExpects = findElements(root, "h2-expect");
  for (const expect of allExpects) {
    const parent = expect.parentNode;
    if (parent === null || !("tagName" in parent) || (parent as Element).tagName !== "h2-agent") {
      throw new CartridgeParseError(
        "cartridge.expect_outside_agent",
        `h2-expect must be a direct child of h2-agent (artifact=${attr(expect, "artifact") ?? "<unnamed>"})`
      );
    }
  }
}

function validateHookPlacement(root: Element): void {
  const allHooks = findElements(root, "h2-hook");
  for (const hook of allHooks) {
    const parent = hook.parentNode;
    if (parent === null || !("tagName" in parent) || (parent as Element).tagName !== "h2-agent") {
      throw new CartridgeParseError(
        "cartridge.hook_outside_agent",
        `h2-hook must be a direct child of h2-agent`
      );
    }
  }
}

function validateInputPlacement(root: Element): void {
  const allInputs = findElements(root, "h2-input");
  for (const input of allInputs) {
    const parent = input.parentNode;
    if (parent === null || !("tagName" in parent) || (parent as Element).tagName !== "h2-agent") {
      throw new CartridgeParseError(
        "cartridge.input_outside_agent",
        "h2-input must be a direct child of h2-agent"
      );
    }
  }
}

function collectLoadEvents(
  manifest: WorkflowManifest,
  root: Element,
  views: WorkflowViewDefinition[],
  nodes: WorkflowNode[]
): WorkflowEventRecord[] {
  const events: WorkflowEventRecord[] = [];
  const timestamp = new Date(0).toISOString();
  const hasHuman = findElements(root, "h2-human").length > 0;
  if (hasHuman && !manifest.declaresHumanInput) {
    events.push({
      index: events.length,
      timestamp,
      type: "manifest.warning.human_input_undeclared",
      data: { detail: "cartridge uses h2-human but manifest does not declare h2-capability name=\"human-input\"" }
    });
  }
  if (views.length > 0 && !manifest.declaresView) {
    events.push({
      index: events.length,
      timestamp,
      type: "manifest.warning.view_undeclared",
      data: { detail: "cartridge uses h2-view but manifest does not declare h2-capability name=\"view\"" }
    });
  }
  const supportedSlots = new Set(["properties"]);
  const reservedSlots = new Set(["main-detail", "artifact", "board"]);
  for (const view of views) {
    if (reservedSlots.has(view.slot)) {
      events.push({
        index: events.length,
        timestamp,
        type: "view.slot_unsupported",
        data: { slot: view.slot, detail: "reserved slot in v0.1; rendering deferred" }
      });
    } else if (!supportedSlots.has(view.slot)) {
      events.push({
        index: events.length,
        timestamp,
        type: "view.slot_unknown",
        data: { slot: view.slot }
      });
    }
  }
  visitNodes(nodes, (node) => {
    if (node.type !== "agent") {
      return;
    }
    const hardHooks = directChildrenByNodeId(root, "h2-agent", node.id)
      .flatMap((agent) => directChildren(agent, "h2-hook"))
      .filter((hook) => attr(hook, "kind") === "hard");
    for (const hook of hardHooks) {
      events.push({
        index: events.length,
        timestamp,
        type: "hook.unsupported",
        data: {
          agent: node.id,
          on: attr(hook, "on")
        }
      });
    }
  });
  return events;
}

function parseBoards(root: Element): WorkflowBoardDefinition[] {
  return findElements(root, "h2-board").map((element) => ({
    id: requiredAttr(element, "id", "h2-board"),
    schema: attr(element, "schema")
  }));
}

function parseEventTypes(root: Element): WorkflowEventDefinition[] {
  const state = directChild(root, "h2-state");
  if (state === undefined) {
    return [];
  }
  return directChildren(state, "h2-event").map((element) => ({
    type: requiredAttr(element, "type", "h2-event")
  }));
}

function parseArtifactTypes(root: Element): WorkflowArtifactDefinition[] {
  const state = directChild(root, "h2-state");
  if (state === undefined) {
    return [];
  }
  return directChildren(state, "h2-artifact").map((element) => ({
    name: requiredAttr(element, "name", "h2-artifact"),
    schema: attr(element, "schema")
  }));
}

function parseTemplates(root: Element): Record<string, string> {
  const templates: Record<string, string> = {};
  for (const element of findElements(root, "h2-template")) {
    templates[requiredAttr(element, "id", "h2-template")] = normalizedText(element);
  }
  return templates;
}

function parseViews(root: Element): WorkflowViewDefinition[] {
  return directChildren(root, "h2-view").map((element) => ({
    slot: requiredAttr(element, "slot", "h2-view"),
    html: innerHtml(element)
  }));
}

function parseNodeChildren(parent: ParentNode): WorkflowNode[] {
  return elementChildren(parent).flatMap((element) => {
    const node = parseNode(element);
    return node === undefined ? [] : [node];
  });
}

function parseNode(element: Element): WorkflowNode | undefined {
  switch (element.tagName) {
    case "h2-sequence":
      return {
        type: "sequence",
        id: attr(element, "id"),
        children: parseNodeChildren(element)
      };
    case "h2-parallel":
      return {
        type: "parallel",
        id: attr(element, "id"),
        children: parseNodeChildren(element)
      };
    case "h2-loop": {
      const whileExpr = attr(element, "while");
      if (whileExpr !== undefined && hasEventRoot(whileExpr)) {
        throw new CartridgeParseError(
          "cartridge.event_root_outside_await",
          `h2-loop while uses event.<type> but event.<type> is only valid inside h2-await on`
        );
      }
      return {
        type: "loop",
        id: requiredAttr(element, "id", "h2-loop"),
        while: whileExpr,
        max: optionalInteger(attr(element, "max")) ?? 1,
        counterLabel: attr(element, "counter-label"),
        children: parseNodeChildren(element)
      };
    }
    case "h2-script":
      return {
        type: "script",
        id: attr(element, "id"),
        uses: requiredAttr(element, "uses", "h2-script")
      };
    case "h2-check":
      return {
        type: "check",
        id: attr(element, "id"),
        uses: requiredAttr(element, "uses", "h2-check")
      };
    case "h2-agent":
      return parseAgent(element);
    case "h2-message":
      return parseMessage(element);
    case "h2-sleep":
      return {
        type: "sleep",
        id: attr(element, "id"),
        durationMs: parseDurationMs(attr(element, "duration-ms") ?? attr(element, "duration") ?? "0")
      };
    case "h2-await":
      return parseAwait(element);
    case "h2-branch":
      return parseBranch(element);
    case "h2-human":
      return parseHuman(element);
    case "h2-transform":
      return {
        type: "transform",
        id: attr(element, "id"),
        from: requiredAttr(element, "from", "h2-transform"),
        to: requiredAttr(element, "to", "h2-transform"),
        uses: attr(element, "uses")
      };
    case "h2-end":
      return {
        type: "end",
        id: attr(element, "id")
      };
    case "h2-expect":
      throw new CartridgeParseError(
        "cartridge.expect_outside_agent",
        "h2-expect must be a direct child of h2-agent; use h2-await for standalone waits"
      );
    case "h2-input":
      throw new CartridgeParseError(
        "cartridge.input_outside_agent",
        "h2-input must be a direct child of h2-agent"
      );
    default:
      if (element.tagName.startsWith("h2-")) {
        throw new CartridgeParseError(
          "cartridge.unknown_element",
          `unknown executable workflow element: ${element.tagName}`
        );
      }
      return undefined;
  }
}

function parseAgent(element: Element): WorkflowAgentNode {
  const prompt = parsePromptAttrs(element);
  return {
    type: "agent",
    id: requiredAttr(element, "id", "h2-agent"),
    tool: parseAgentTool(requiredAttr(element, "tool", "h2-agent")),
    role: attr(element, "role"),
    parent: attr(element, "parent"),
    promptRef: prompt.promptRef,
    promptText: prompt.promptText,
    shortName: attr(element, "short-name") ?? attr(element, "shortName"),
    timeoutMs: optionalDurationMs(attr(element, "timeout-ms") ?? attr(element, "timeout")),
    inputs: directChildren(element, "h2-input").map(parseAgentInput),
    expects: directChildren(element, "h2-expect").map(parseExpectation),
    hooks: directChildren(element, "h2-hook").map(parseHook)
  };
}

function parseMessage(element: Element): WorkflowMessageNode {
  const prompt = parsePromptAttrs(element);
  return {
    type: "message",
    id: attr(element, "id"),
    target: requiredAttr(element, "target", "h2-message"),
    promptRef: prompt.promptRef,
    promptText: prompt.promptText,
    shortName: attr(element, "short-name") ?? attr(element, "shortName"),
    timeoutMs: optionalDurationMs(attr(element, "timeout-ms") ?? attr(element, "timeout"))
  };
}

function parseAwait(element: Element): WorkflowAwaitNode {
  return {
    type: "await",
    id: attr(element, "id"),
    on: requiredAttr(element, "on", "h2-await"),
    timeoutMs: optionalDurationMs(attr(element, "timeout-ms") ?? attr(element, "timeout"))
  };
}

function parseExpectation(element: Element): WorkflowExpectation {
  return {
    artifact: requiredAttr(element, "artifact", "h2-expect"),
    schema: attr(element, "schema")
  };
}

function parseAgentInput(element: Element): WorkflowAgentInput {
  const artifact = attr(element, "artifact");
  const board = attr(element, "board");
  if ((artifact === undefined) === (board === undefined)) {
    throw new CartridgeParseError(
      "cartridge.input_source",
      "h2-input requires exactly one of artifact or board"
    );
  }
  const label = attr(element, "label");
  const optional = parseBooleanAttr(attr(element, "optional"));
  if (artifact !== undefined) {
    return {
      kind: "artifact",
      name: requiredAttr(element, "artifact", "h2-input"),
      schema: attr(element, "schema"),
      label,
      optional
    };
  }
  return {
    kind: "board",
    id: requiredAttr(element, "board", "h2-input"),
    label,
    optional
  };
}

function parseHook(element: Element): WorkflowHookDefinition {
  const kind = attr(element, "kind") ?? "soft";
  if (kind !== "soft" && kind !== "hard") {
    throw new CartridgeParseError("cartridge.unsupported_hook_kind", `unsupported h2-hook kind: ${kind}`);
  }
  const hook: WorkflowHookDefinition = { kind: "soft" };
  const on = attr(element, "on");
  const artifact = attr(element, "artifact");
  const schema = attr(element, "schema");
  if (on !== undefined) {
    hook.on = on;
  }
  if (artifact !== undefined) {
    hook.artifact = artifact;
  }
  if (schema !== undefined) {
    hook.schema = schema;
  }
  return hook;
}

function parseBranch(element: Element): WorkflowBranchNode {
  const cases = directChildren(element, "h2-case").map(parseCase);
  const defaultChildren = directChildren(element, "h2-default");
  if (defaultChildren.length === 0) {
    throw new CartridgeParseError(
      "cartridge.branch_missing_default",
      `h2-branch ${attr(element, "id") ?? "<anonymous>"} must contain exactly one h2-default child`
    );
  }
  if (defaultChildren.length > 1) {
    throw new CartridgeParseError(
      "cartridge.branch_multiple_default",
      `h2-branch ${attr(element, "id") ?? "<anonymous>"} must contain exactly one h2-default child`
    );
  }
  const defaultTarget = requiredAttr(defaultChildren[0], "goto", "h2-default");
  const onExpr = requiredAttr(element, "on", "h2-branch");
  if (hasEventRoot(onExpr)) {
    throw new CartridgeParseError(
      "cartridge.event_root_outside_await",
      `h2-branch on uses event.<type> but event.<type> is only valid inside h2-await on`
    );
  }
  return {
    type: "branch",
    id: attr(element, "id"),
    on: onExpr,
    cases,
    defaultTarget
  };
}

function hasEventRoot(expression: string): boolean {
  // `event` is a path root when the identifier is followed by `.` and is not preceded
  // by characters that would make it a non-root token. Inside a longer path (after a `.`
  // separator) `event` would be a field segment, not a root, so a preceding `.` (or any
  // identifier character) disqualifies. This is conservative enough to catch the spec
  // ban on `event.<type>` outside h2-await on while leaving `artifact.event.foo` alone.
  return /(?:^|[^A-Za-z0-9_\-\.])event\s*\./.test(expression);
}

function parseHuman(element: Element): WorkflowHumanNode {
  const prompt = parsePromptAttrs(element);
  return {
    type: "human",
    id: attr(element, "id"),
    promptRef: prompt.promptRef,
    promptText: prompt.promptText,
    artifact: attr(element, "artifact"),
    schema: attr(element, "schema")
  };
}

function parseCase(element: Element): WorkflowCase {
  const value = requiredAttr(element, "value", "h2-case");
  const gotoAttr = attr(element, "goto");
  const continueAttr = attr(element, "continue");
  if (gotoAttr !== undefined && continueAttr !== undefined) {
    throw new CartridgeParseError(
      "cartridge.case_conflict",
      `h2-case ${value} cannot declare both goto and continue`
    );
  }
  if (gotoAttr === undefined && continueAttr === undefined) {
    throw new CartridgeParseError(
      "cartridge.case_missing_target",
      `h2-case ${value} must declare either goto or continue`
    );
  }
  return {
    value,
    goto: gotoAttr,
    continueLoop: continueAttr
  };
}

function parsePromptAttrs(element: Element): { promptRef?: string; promptText?: string } {
  const prompt = attr(element, "prompt");
  if (prompt === undefined) {
    return {};
  }
  if (prompt.startsWith("#")) {
    return { promptRef: prompt.slice(1) };
  }
  return { promptText: prompt };
}

function parseAgentTool(value: string) {
  if (value === "codex" || value === "claude") {
    return value;
  }
  throw new CartridgeParseError("cartridge.unsupported_tool", `unsupported agent tool: ${value}`);
}

function findElements(parent: ParentNode, tagName: string): Element[] {
  const matches: Element[] = [];
  for (const child of parent.childNodes) {
    if (isElement(child)) {
      if (child.tagName === tagName) {
        matches.push(child);
      }
      matches.push(...findElements(child, tagName));
    }
  }
  return matches;
}

function directChild(parent: ParentNode, tagName: string): Element | undefined {
  return directChildren(parent, tagName)[0];
}

function directChildren(parent: ParentNode, tagName: string): Element[] {
  return elementChildren(parent).filter((child) => child.tagName === tagName);
}

function elementChildren(parent: ParentNode): Element[] {
  return parent.childNodes.filter(isElement);
}

function isElement(node: ChildNode): node is Element {
  return "tagName" in node;
}

function attr(element: Element, name: string): string | undefined {
  return element.attrs.find((item) => item.name === name)?.value;
}

function requiredAttr(element: Element, name: string, tagName: string): string {
  const value = attr(element, name);
  if (value === undefined || value.length === 0) {
    throw new CartridgeParseError(
      "cartridge.missing_attribute",
      `${tagName} requires ${name}`
    );
  }
  return value;
}

function normalizedText(element: Element): string {
  return textContent(element).trim().replace(/\s+/g, " ");
}

function textContent(parent: ParentNode): string {
  return parent.childNodes.map((child) => {
    if (isElement(child)) {
      return textContent(child);
    }
    if (child.nodeName === "#text") {
      return child.value;
    }
    return "";
  }).join("");
}

function innerHtml(element: Element): string {
  return element.childNodes.map((child) => serializeOuter(child)).join("").trim();
}

function optionalDurationMs(value: string | undefined): number | undefined {
  return value === undefined ? undefined : parseDurationMs(value);
}

function parseBooleanAttr(value: string | undefined): boolean {
  return value === "" || value === "true";
}

function optionalInteger(value: string | undefined): number | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (!/^\d+$/.test(value)) {
    throw new CartridgeParseError("cartridge.invalid_integer", `invalid integer: ${value}`);
  }
  return Number.parseInt(value, 10);
}

function parseDurationMs(value: string): number {
  const trimmed = value.trim();
  if (/^\d+$/.test(trimmed)) {
    return Number.parseInt(trimmed, 10);
  }
  const match = /^(\d+)(ms|s|m|h)$/.exec(trimmed);
  if (match === null) {
    throw new CartridgeParseError("cartridge.invalid_duration", `invalid duration: ${value}`);
  }
  const amount = Number.parseInt(match[1], 10);
  switch (match[2]) {
    case "ms":
      return amount;
    case "s":
      return amount * 1_000;
    case "m":
      return amount * 60_000;
    case "h":
      return amount * 3_600_000;
    default:
      return amount;
  }
}

function directChildrenByNodeId(root: ParentNode, tagName: string, id: string): Element[] {
  return findElements(root, tagName).filter((element) => attr(element, "id") === id);
}

function visitNodes(nodes: WorkflowNode[], visitor: (node: WorkflowNode) => void): void {
  for (const node of nodes) {
    visitor(node);
    if (node.type === "sequence" || node.type === "parallel" || node.type === "loop") {
      visitNodes(node.children, visitor);
    }
  }
}
