import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, resolve as resolvePathFs } from "node:path";

import { parseFragment, serializeOuter, type DefaultTreeAdapterTypes } from "parse5";

import type { AgentId, WorkflowAgentInputSnapshot } from "../agents/types.js";
import type { RunAgentInput } from "../service.js";
import type { AgentRunCoordinator, AgentRunRecord, SendMessageInput } from "../hub/runs.js";
import { parseWorkflowCartridge } from "./parser.js";
import { compileGraph, GraphCompileError } from "./graph.js";
import { evaluatePredicate, resolvePath, type PredicateContext, type WorkflowExpressionWarning } from "./expression.js";
import { buildWorkflowProjection } from "./projection.js";
import { initializeRlcrGoalTrackerBoard, updateRlcrLoopStatusBoard } from "./rlcr-board.js";
import type {
  ArtifactRecord,
  ArtifactValidationStatus,
  BoardRecord,
  DeliverArtifactInput,
  Edge,
  GetArtifactInput,
  GetBoardInput,
  GraphInstance,
  LoadWorkflowHtmlInput,
  PatchBoardInput,
  StartWorkflowInput,
  Vertex,
  WorkflowAgentNode,
  WorkflowAgentInput,
  WorkflowAwaitNode,
  WorkflowBranchNode,
  WorkflowCartridge,
  WorkflowEventRecord,
  WorkflowHumanNode,
  WorkflowMessageNode,
  WorkflowRunRecord,
  WorkflowSleepNode,
  WorkflowTransformNode,
  WorkflowWaitTarget
} from "./types.js";
import type { WorkflowStore } from "./storage.js";
import type { WorkflowSchedulerSnapshot } from "./types.js";
import { createDefaultSchemaRegistry, type SchemaRegistry } from "./schema-registry.js";
import { createDefaultScriptRegistry, type ScriptAdapterKind, type ScriptRegistry } from "./script-registry.js";

export class WorkflowLoadError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
    this.name = "WorkflowLoadError";
  }
}

export interface WorkflowCoordinatorOptions {
  idFactory?: () => string;
  now?: () => string;
  store?: WorkflowStore;
  softEnforcementRetryMax?: number;
  authorizedAgentTools?: string[];
  authorizedScripts?: (uses: string) => boolean;
  scriptRegistry?: ScriptRegistry;
  loadPathRoots?: string[];
  /**
   * Hub-managed schema registry consulted at artifact delivery. When omitted
   * the coordinator builds a permissive default registry that covers the
   * schema names referenced by bundled cartridges. Hosts that need stricter
   * content validation should construct a registry with typed validators and
   * pass it here.
   */
  schemaRegistry?: SchemaRegistry;
}

const DEFAULT_SOFT_RETRY_MAX = 3;
const DEFAULT_AUTHORIZED_AGENT_TOOLS: string[] = ["codex", "claude"];
/**
 * MCP tool names a workflow-spawned agent can invoke against the hub. Kept
 * stable as a contract surface for cartridge authors; the dotted JSON-RPC
 * equivalents are derived mechanically by replacing each underscore with a
 * dot, per the spec "MCP and JSON-RPC Surface" section.
 */
const WORKFLOW_AGENT_MCP_TOOL_NAMES: readonly string[] = Object.freeze([
  "agent_spawn_child",
  "agent_send_message",
  "agent_wait",
  "artifact_deliver",
  "board_patch",
  "board_get",
  "artifact_get",
  "event_emit",
  "view_publish",
  "human_request",
  "human_answer"
]);

interface CompiledCartridge {
  cartridge: WorkflowCartridge;
  graph: GraphInstance;
}

interface AgentVertexState {
  runChain: string[];
  retryCount: number;
}

interface ActiveWorkflowRun {
  cartridge: WorkflowCartridge;
  graph: GraphInstance;
  frontier: Set<string>;
  inflight: Set<string>;
  completed: Set<string>;
  joinArrivals: Map<string, number>;
  loopIterations: Map<string, number>;
  artifactWaiters: Map<string, Set<() => void>>;
  boardWaiters: Set<() => void>;
  predicateWaiters: Set<() => void>;
  predicateRevalidators: Set<() => void>;
  agentRetryCounts: Map<string, number>;
  emittedEventTypes: Set<string>;
  awaitEventBaseline: Map<string, number>;
  agentVertexState: Map<string, AgentVertexState>;
  settled: Promise<void>;
  resolveSettled: () => void;
  scheduleTick: () => void;
}

export class WorkflowCoordinator {
  private readonly cartridges = new Map<string, CompiledCartridge>();
  private readonly runs = new Map<string, WorkflowRunRecord>();
  private readonly activeRuns = new Map<string, ActiveWorkflowRun>();
  private readonly events = new EventEmitter();
  private readonly idFactory: () => string;
  private readonly now: () => string;
  private readonly softEnforcementRetryMax: number;
  private readonly authorizedAgentTools: Set<string>;
  private readonly authorizedScript: ((uses: string) => boolean) | undefined;
  private readonly scriptRegistry: ScriptRegistry;
  private readonly loadPathRoots: string[];
  private readonly schemaRegistry: SchemaRegistry;

  constructor(
    private readonly runCoordinator: AgentRunCoordinator,
    private readonly options: WorkflowCoordinatorOptions = {}
  ) {
    this.idFactory = options.idFactory ?? randomId;
    this.now = options.now ?? (() => new Date().toISOString());
    this.softEnforcementRetryMax = options.softEnforcementRetryMax ?? DEFAULT_SOFT_RETRY_MAX;
    this.authorizedAgentTools = new Set(options.authorizedAgentTools ?? DEFAULT_AUTHORIZED_AGENT_TOOLS);
    this.authorizedScript = options.authorizedScripts;
    this.scriptRegistry = options.scriptRegistry ?? createDefaultScriptRegistry();
    this.loadPathRoots = options.loadPathRoots ?? [process.cwd(), homedir()];
    this.schemaRegistry = options.schemaRegistry ?? createDefaultSchemaRegistry();
  }

  async loadHtml(input: LoadWorkflowHtmlInput): Promise<WorkflowCartridge> {
    let resolvedPath: string | undefined;
    if (input.path !== undefined) {
      resolvedPath = isAbsolute(input.path) ? input.path : resolvePathFs(input.path);
      const allowed = this.loadPathRoots.some((root) => isUnderRoot(resolvedPath!, root));
      if (!allowed) {
        throw new WorkflowLoadError(
          "workflow.load_path_denied",
          `workflow.load_html path is outside the allowed roots: ${resolvedPath}`
        );
      }
    }
    const html = input.html ?? (resolvedPath === undefined ? undefined : await readFile(resolvedPath, "utf8"));
    if (html === undefined) {
      throw new Error("workflow.load_html requires html or path");
    }
    const cartridge = parseWorkflowCartridge({
      html,
      sourcePath: input.sourcePath ?? resolvedPath
    });
    if (resolvedPath !== undefined) {
      const parentBase = basename(dirname(resolvedPath));
      if (parentBase !== cartridge.id) {
        throw new WorkflowLoadError(
          "cartridge.id_mismatch",
          `cartridge id "${cartridge.id}" does not match directory basename "${parentBase}"`
        );
      }
    }
    this.validateManifest(cartridge);
    let graph: GraphInstance;
    try {
      graph = compileGraph(cartridge);
    } catch (error) {
      if (error instanceof GraphCompileError) {
        throw error;
      }
      throw error;
    }
    this.cartridges.set(cartridge.id, { cartridge, graph });
    this.options.store?.recordCartridge(cartridge);
    return clone(cartridge);
  }

  private validateManifest(cartridge: WorkflowCartridge): void {
    const manifest = cartridge.manifest;
    const seenAgentTools = new Set<string>();
    const seenScripts = new Map<string, Set<ScriptAdapterKind>>();
    visitNodes(cartridge.nodes, (node) => {
      if (node.type === "agent") {
        seenAgentTools.add(node.tool);
      } else if (node.type === "script" || node.type === "check") {
        addSeenScript(seenScripts, node.uses, node.type);
      } else if (node.type === "transform" && node.uses !== undefined) {
        addSeenScript(seenScripts, node.uses, "transform");
      }
    });
    // Hard-tier rule: if any agent/script/check vertices exist, the manifest must explicitly
    // declare the corresponding capability. Treat an absent capability as an empty allowed set
    // so that missing declarations fail load, not silently bypass.
    const agentToolsAllowed = seenAgentTools.size > 0 ? new Set(manifest.agentTools) : undefined;
    const scriptAllowed = seenScripts.size > 0 ? new Set(manifest.scriptAllowlist) : undefined;
    for (const tool of seenAgentTools) {
      if (agentToolsAllowed !== undefined && !agentToolsAllowed.has(tool)) {
        throw new WorkflowLoadError(
          "manifest.error.tool_undeclared",
          `cartridge uses agent tool "${tool}" but h2-manifest does not declare it`
        );
      }
      if (!this.authorizedAgentTools.has(tool)) {
        throw new WorkflowLoadError(
          "manifest.error.tool_unauthorized",
          `cartridge uses agent tool "${tool}" which is not authorized in the hub configuration`
        );
      }
    }
    for (const [uses, kinds] of seenScripts) {
      if (scriptAllowed !== undefined && !scriptAllowed.has(uses)) {
        throw new WorkflowLoadError(
          "manifest.error.script_undeclared",
          `cartridge invokes script "${uses}" but h2-manifest does not declare it`
        );
      }
      const descriptor = this.scriptRegistry.get(uses);
      if (descriptor === undefined) {
        throw new WorkflowLoadError(
          "manifest.error.script_adapter_unknown",
          `cartridge invokes script "${uses}" which is not registered by the hub runtime`
        );
      }
      for (const kind of kinds) {
        if (!descriptor.kinds.includes(kind)) {
          throw new WorkflowLoadError(
            "manifest.error.script_adapter_kind_mismatch",
            `cartridge invokes script "${uses}" as ${kind}, but the registered adapter does not support that use`
          );
        }
      }
      if (this.authorizedScript !== undefined && !this.authorizedScript(uses)) {
        throw new WorkflowLoadError(
          "manifest.error.script_unauthorized",
          `cartridge invokes script "${uses}" which is not authorized by the hub runtime`
        );
      }
    }
  }

  start(input: StartWorkflowInput): WorkflowRunRecord {
    const compiled = this.cartridges.get(input.cartridgeId);
    if (compiled === undefined) {
      throw new Error(`Unknown workflow cartridge: ${input.cartridgeId}`);
    }
    const { cartridge, graph } = compiled;
    if (input.agentToolOverride !== undefined) {
      this.assertAgentToolOverrideAllowed(cartridge, input.agentToolOverride);
    }

    const id = this.idFactory();
    const timestamp = this.now();
    const cwd = input.cwd === undefined ? undefined : resolvePathFs(input.cwd);
    const vars: Record<string, string> = {};
    for (const definition of cartridge.vars) {
      vars[definition.name] = definition.value;
    }
    const run: WorkflowRunRecord = {
      id,
      cartridgeId: cartridge.id,
      cartridgeName: cartridge.name,
      cwd,
      agentToolOverride: input.agentToolOverride,
      status: "running",
      createdAt: timestamp,
      startedAt: timestamp,
      waitingFor: [],
      nodeRunIds: {},
      boards: cartridge.boards.map((board) => ({
        id: board.id,
        schema: board.schema,
        value: {},
        updatedAt: timestamp
      })),
      artifacts: [],
      views: cartridge.views,
      events: [],
      loopIterations: {},
      vars
    };

    let resolveSettled = () => {};
    const settled = new Promise<void>((resolve) => {
      resolveSettled = resolve;
    });

    let tickScheduled = false;
    const active: ActiveWorkflowRun = {
      cartridge,
      graph,
      frontier: new Set([graph.startVertexId]),
      inflight: new Set(),
      completed: new Set(),
      joinArrivals: new Map(),
      loopIterations: new Map(),
      artifactWaiters: new Map(),
      boardWaiters: new Set(),
      predicateWaiters: new Set(),
      predicateRevalidators: new Set(),
      agentRetryCounts: new Map(),
      emittedEventTypes: new Set(),
      awaitEventBaseline: new Map(),
      agentVertexState: new Map(),
      settled,
      resolveSettled,
      scheduleTick: () => {
        if (tickScheduled) {
          return;
        }
        tickScheduled = true;
        queueMicrotask(() => {
          tickScheduled = false;
          this.tick(run).catch((error) => {
            this.failRun(run, error);
          });
        });
      }
    };

    this.runs.set(id, run);
    this.activeRuns.set(id, active);
    this.recordEvent(run, "workflow.started", { cartridgeId: cartridge.id });
    for (const loadEvent of cartridge.loadEvents) {
      this.recordEvent(run, loadEvent.type, loadEvent.data);
    }
    active.scheduleTick();
    return clone(run);
  }

  private assertAgentToolOverrideAllowed(cartridge: WorkflowCartridge, agent: AgentId): void {
    if (!cartridge.manifest.agentTools.includes(agent)) {
      throw new Error(`workflow agent tool override is not declared by cartridge manifest: ${agent}`);
    }
    if (!this.authorizedAgentTools.has(agent)) {
      throw new Error(`workflow agent tool override is not authorized by the hub runtime: ${agent}`);
    }
  }

  getRun(id: string): WorkflowRunRecord {
    return clone(this.requireRun(id));
  }

  listRuns(): WorkflowRunRecord[] {
    return [...this.runs.values()].map(clone);
  }

  async sendMessage(input: SendMessageInput): Promise<AgentRunRecord> {
    const handoff = this.findActiveAgentHandoff(input.runId);
    const continuation = await this.runCoordinator.sendMessage(input);
    if (handoff === undefined) {
      return continuation;
    }

    const { run, nodeId, active } = handoff;
    const state = active.agentVertexState.get(nodeId);
    if (state !== undefined) {
      const lastRunId = state.runChain[state.runChain.length - 1];
      if (lastRunId === input.runId) {
        state.runChain.push(continuation.id);
      } else if (!state.runChain.includes(continuation.id)) {
        state.runChain.push(continuation.id);
      }
    }
    run.nodeRunIds[nodeId] = continuation.id;
    this.recordEvent(run, "agent.message_sent", { target: nodeId, runId: continuation.id });
    this.persistSnapshot(run);
    return continuation;
  }

  loadStoredRun(input: { run: WorkflowRunRecord; cartridge?: WorkflowCartridge }): WorkflowRunRecord {
    const existing = this.runs.get(input.run.id);
    if (existing !== undefined) {
      return clone(existing);
    }
    if (input.cartridge !== undefined && !this.cartridges.has(input.cartridge.id)) {
      const graph = compileGraph(input.cartridge);
      this.cartridges.set(input.cartridge.id, { cartridge: input.cartridge, graph });
    }
    const run = normalizeStoredRun(input.run);
    this.runs.set(run.id, run);
    return clone(run);
  }

  /**
   * List runs with `data-h2-bind` view fragments pre-resolved using the same expression
   * grammar as predicates and transforms. The dashboard renders the returned HTML
   * directly, eliminating client-side drift between view paths and predicate paths.
   */
  listRunsWithRenderedViews(): WorkflowRunRecord[] {
    return [...this.runs.values()].map((run) => {
      const cloned = clone(run);
      const compiled = this.cartridges.get(run.cartridgeId);
      if (compiled === undefined) {
        return cloned;
      }
      cloned.projection = buildWorkflowProjection(compiled.cartridge, compiled.graph, cloned);
      cloned.views = cloned.views.map((view) => ({
        slot: view.slot,
        html: renderViewHtml(view.html, compiled.graph, cloned)
      }));
      return cloned;
    });
  }

  async waitForRun(id: string, timeoutMs = 600_000): Promise<WorkflowRunRecord> {
    const run = this.requireRun(id);
    if (isTerminal(run.status)) {
      return clone(run);
    }
    const active = this.activeRuns.get(id);
    if (active === undefined) {
      return clone(run);
    }

    let timeout: NodeJS.Timeout | undefined;
    await Promise.race([
      active.settled,
      new Promise<void>((_, reject) => {
        timeout = setTimeout(() => reject(new Error(`Timed out waiting for workflow run: ${id}`)), timeoutMs);
      })
    ]);
    if (timeout !== undefined) {
      clearTimeout(timeout);
    }
    return this.getRun(id);
  }

  deliverArtifact(input: DeliverArtifactInput): ArtifactRecord {
    const run = this.requireRun(input.workflowRunId);
    const active = this.activeRuns.get(run.id);
    const cartridge = active?.cartridge ?? this.cartridges.get(run.cartridgeId)?.cartridge;
    const iteration = currentIterationForRun(active);
    const content = normalizeDeliveredContent(input.content);
    const normalizedInput: DeliverArtifactInput = {
      ...input,
      content
    };
    const validationStatus = this.computeValidationStatus(cartridge, normalizedInput);
    const artifact: ArtifactRecord = {
      id: this.idFactory(),
      workflowRunId: run.id,
      name: input.name,
      schema: input.schema,
      producer: input.producer,
      iteration,
      content,
      createdAt: this.now(),
      validationStatus
    };
    run.artifacts.push(artifact);
    this.recordEvent(run, "artifact.delivered", {
      name: artifact.name,
      producer: artifact.producer,
      iteration,
      validationStatus
    });
    if (validationStatus === "manifest-undeclared") {
      this.recordEvent(run, "manifest.warning.artifact_undeclared", {
        artifact: input.name,
        schema: input.schema
      });
    } else if (validationStatus === "schema-mismatch") {
      this.recordEvent(run, "artifact.schema_mismatch", {
        artifact: input.name,
        schema: input.schema
      });
    }
    const duplicates = run.artifacts.filter((existing) => existing.name === input.name && existing.iteration === iteration);
    if (duplicates.length > 1) {
      this.recordEvent(run, "artifact.double_delivery", {
        artifact: input.name,
        iteration,
        deliveryCount: duplicates.length
      });
    }
    notifyArtifactWaiters(active, input.name);
    notifyPredicateWaiters(active);
    return clone(artifact);
  }

  getArtifact(input: GetArtifactInput): ArtifactRecord {
    const artifacts = this.requireRun(input.workflowRunId).artifacts;
    const artifact = [...artifacts].reverse().find((item) => item.name === input.name);
    if (artifact === undefined) {
      throw new Error(`Unknown artifact: ${input.name}`);
    }
    return clone(artifact);
  }

  patchBoard(input: PatchBoardInput): BoardRecord {
    const run = this.requireRun(input.workflowRunId);
    const board = run.boards.find((item) => item.id === input.boardId);
    if (board === undefined) {
      throw new Error(`Unknown board: ${input.boardId}`);
    }
    board.value = {
      ...board.value,
      ...input.patch
    };
    board.updatedAt = this.now();
    this.recordEvent(run, "board.patched", { boardId: board.id });
    const active = this.activeRuns.get(run.id);
    notifyBoardWaiters(active);
    notifyPredicateWaiters(active);
    return clone(board);
  }

  getBoard(input: GetBoardInput): BoardRecord {
    const board = this.requireRun(input.workflowRunId).boards.find((item) => item.id === input.boardId);
    if (board === undefined) {
      throw new Error(`Unknown board: ${input.boardId}`);
    }
    return clone(board);
  }

  humanRequest(input: { workflowRunId: string; prompt?: string; artifact: string; schema?: string; vertex?: string }): WorkflowRunRecord {
    const run = this.requireRun(input.workflowRunId);
    const active = this.activeRuns.get(run.id);
    this.recordEvent(run, "human.requested", {
      prompt: input.prompt,
      artifact: input.artifact,
      schema: input.schema,
      vertex: input.vertex ?? "external"
    });
    run.waitingFor = [
      ...run.waitingFor,
      {
        kind: "human",
        vertex: input.vertex ?? "external",
        prompt: input.prompt,
        artifact: input.artifact,
        schema: input.schema
      }
    ];
    if (run.status === "running") {
      run.status = "waiting";
    }
    if (active === undefined) {
      this.options.store?.recordRun(clone(run));
    }
    return clone(run);
  }

  humanAnswer(input: { workflowRunId: string; artifact: string; schema?: string; content: unknown }): ArtifactRecord {
    return this.deliverArtifact({
      workflowRunId: input.workflowRunId,
      name: input.artifact,
      schema: input.schema,
      producer: "human",
      content: input.content
    });
  }

  emitEvent(input: { workflowRunId: string; type: string; data?: unknown }): WorkflowEventRecord {
    const run = this.requireRun(input.workflowRunId);
    const record: WorkflowEventRecord = {
      index: run.events.length,
      timestamp: this.now(),
      type: input.type,
      data: input.data
    };
    run.events.push(record);
    const active = this.activeRuns.get(run.id);
    if (active !== undefined) {
      active.emittedEventTypes.add(input.type);
    }
    notifyPredicateWaiters(active);
    this.options.store?.recordRun(clone(run));
    return { ...record };
  }

  publishView(input: { workflowRunId: string; slot: string; html?: string; data?: unknown }): WorkflowEventRecord {
    return this.emitEvent({
      workflowRunId: input.workflowRunId,
      type: "view.published",
      data: { slot: input.slot, html: input.html, data: input.data }
    });
  }

  private async tick(run: WorkflowRunRecord): Promise<void> {
    const active = this.activeRuns.get(run.id);
    if (active === undefined || isTerminal(run.status)) {
      return;
    }
    const { graph, frontier, inflight, completed } = active;

    const ready = [...frontier].filter((vertexId) => !inflight.has(vertexId) && !completed.has(vertexId));
    if (ready.length === 0) {
      this.updateWaitingFor(run, active);
      if (inflight.size === 0 && frontier.size === 0) {
        this.maybeFinish(run, active);
      }
      return;
    }

    for (const vertexId of ready) {
      frontier.delete(vertexId);
      if (vertexId === graph.endVertexId) {
        completed.add(vertexId);
        run.status = "succeeded";
        run.waitingFor = [];
        run.finishedAt = this.now();
        this.recordEvent(run, "workflow.succeeded");
        this.maybeFinish(run, active);
        return;
      }
      inflight.add(vertexId);
      this.fireVertex(run, active, vertexId).catch((error) => {
        this.failRun(run, error);
      });
    }

    this.updateWaitingFor(run, active);
  }

  private async fireVertex(run: WorkflowRunRecord, active: ActiveWorkflowRun, vertexId: string): Promise<void> {
    const vertex = active.graph.vertices.get(vertexId);
    if (vertex === undefined) {
      throw new Error(`Unknown vertex: ${vertexId}`);
    }

    this.recordEvent(run, "vertex.started", { vertexId, kind: vertex.kind });

    try {
      const chosenEdges = await this.executeVertex(run, active, vertex);
      active.inflight.delete(vertexId);
      active.completed.add(vertexId);
      this.recordEvent(run, "vertex.completed", { vertexId, kind: vertex.kind });
      this.routeDownstream(run, active, vertex, chosenEdges);
      active.scheduleTick();
    } catch (error) {
      active.inflight.delete(vertexId);
      throw error;
    }
  }

  private async executeVertex(
    run: WorkflowRunRecord,
    active: ActiveWorkflowRun,
    vertex: Vertex
  ): Promise<Edge[] | undefined> {
    switch (vertex.kind) {
      case "start":
      case "end":
      case "sequence":
      case "parallel-fork":
      case "parallel-join":
        return undefined;
      case "end-marker":
        this.recordEvent(run, "workflow.end_marker", { vertexId: vertex.id });
        return undefined;
      case "loop-entry":
        return this.executeLoopEntry(run, active, vertex);
      case "loop-tail":
        return this.executeLoopTail(run, active, vertex);
      case "branch":
        return this.executeBranch(run, active, vertex);
      case "agent":
        await this.executeAgent(run, active, vertex);
        return undefined;
      case "message":
        await this.executeMessage(run, active, vertex);
        return undefined;
      case "human":
        await this.executeHuman(run, active, vertex);
        return undefined;
      case "await":
        await this.executeAwait(run, active, vertex);
        return undefined;
      case "script":
        this.executeScript(run, vertex);
        return undefined;
      case "check":
        this.executeCheck(run, vertex);
        return undefined;
      case "transform":
        this.executeTransform(run, active, vertex);
        return undefined;
      case "sleep":
        await this.executeSleep(vertex);
        return undefined;
      default:
        return undefined;
    }
  }

  private executeLoopEntry(
    run: WorkflowRunRecord,
    active: ActiveWorkflowRun,
    vertex: Vertex
  ): Edge[] | undefined {
    const loopMeta = active.graph.loops.get(vertex.id);
    if (loopMeta === undefined) {
      return undefined;
    }
    const existing = active.loopIterations.get(vertex.id) ?? 0;
    const next = existing + 1;
    active.loopIterations.set(vertex.id, next);
    run.loopIterations[vertex.id] = next;
    this.recordEvent(run, "loop.iteration_started", { loopId: vertex.id, iteration: next });
    return undefined;
  }

  private executeLoopTail(
    run: WorkflowRunRecord,
    active: ActiveWorkflowRun,
    vertex: Vertex
  ): Edge[] {
    const loopId = vertex.enclosingLoopId;
    if (loopId === undefined) {
      throw new Error(`loop-tail ${vertex.id} has no enclosing loop`);
    }
    const loopMeta = active.graph.loops.get(loopId);
    if (loopMeta === undefined) {
      throw new Error(`loop ${loopId} not registered`);
    }
    const iteration = active.loopIterations.get(loopMeta.entryVertexId) ?? 0;
    const guard = iteration < loopMeta.max && evaluateLoopGuard(active, run, loopMeta.whileExpr, loopId);
    const outgoing = active.graph.outgoing.get(vertex.id) ?? [];
    const backEdge = outgoing.find((edge) => edge.kind === "backedge");
    const fallthrough = outgoing.find((edge) => edge.kind === "fallthrough");
    if (guard && backEdge !== undefined) {
      this.recordEvent(run, "loop.continue", { loopId, iteration });
      return [backEdge];
    }
    this.recordEvent(run, "loop.exit", { loopId, iteration });
    return fallthrough === undefined ? [] : [fallthrough];
  }

  private executeBranch(
    run: WorkflowRunRecord,
    active: ActiveWorkflowRun,
    vertex: Vertex
  ): Edge[] {
    const node = vertex.node as WorkflowBranchNode;
    const warnings: WorkflowExpressionWarning[] = [];
    const value = resolvePath(predicateContextFor(active, vertex), run, node.on, warnings);
    this.emitExpressionWarnings(run, warnings);
    this.recordEvent(run, "branch.evaluated", { branchId: vertex.id, on: node.on, value });
    const outgoing = active.graph.outgoing.get(vertex.id) ?? [];
    const matched = outgoing.find((edge) => edge.kind === "branch" && edge.matchValue !== undefined && String(value) === edge.matchValue)
      ?? outgoing.find((edge) => edge.kind === "continue-edge" && edge.matchValue !== undefined && String(value) === edge.matchValue);
    if (matched !== undefined) {
      this.recordEvent(run, "branch.routed", { branchId: vertex.id, target: matched.to, kind: matched.kind });
      return [matched];
    }
    const fallback = outgoing.find((edge) => edge.kind === "branch-default");
    if (fallback === undefined) {
      throw new Error(`Branch ${vertex.id} has no default edge`);
    }
    this.recordEvent(run, "branch.routed", { branchId: vertex.id, target: fallback.to, kind: "branch-default" });
    return [fallback];
  }

  private async executeAgent(
    run: WorkflowRunRecord,
    active: ActiveWorkflowRun,
    vertex: Vertex
  ): Promise<void> {
    const node = vertex.node as WorkflowAgentNode;
    const existingState = active.agentVertexState.get(node.id);
    let chainState: AgentVertexState;
    if (existingState !== undefined && existingState.runChain.length > 0) {
      chainState = existingState;
      this.recordEvent(run, "agent.resumed", {
        nodeId: node.id,
        runChain: [...chainState.runChain],
        retryCount: chainState.retryCount
      });
    } else {
      const shortName = node.shortName ?? node.id;
      const agentTool = run.agentToolOverride ?? node.tool;
      const request: RunAgentInput = {
        agent: agentTool as AgentId,
        prompt: resolvePrompt(active.cartridge, node.promptRef, node.promptText),
        cwd: run.cwd,
        shortName,
        timeoutMs: node.timeoutMs,
        workflowContext: {
          workflowRunId: run.id,
          vertexId: node.id,
          shortName,
          jsonRpcUrl: this.runCoordinator.jsonRpcUrl,
          expectedArtifacts: node.expects.map((expectation) => ({
            name: expectation.artifact,
            schema: expectation.schema
          })),
          inputs: buildWorkflowInputSnapshots(run, node.inputs ?? []),
          mcpToolNames: WORKFLOW_AGENT_MCP_TOOL_NAMES
        }
      };
      const initialAgentRun = this.runCoordinator.createRun(request, {
        parentRunId: node.parent === undefined ? undefined : run.nodeRunIds[node.parent]
      });
      run.nodeRunIds[node.id] = initialAgentRun.id;
      chainState = {
        runChain: [initialAgentRun.id],
        retryCount: active.agentRetryCounts.get(`${node.id}@${currentIterationForRun(active) ?? 1}`) ?? 0
      };
      active.agentVertexState.set(node.id, chainState);
      this.recordEvent(run, "agent.started", { nodeId: node.id, runId: initialAgentRun.id });
    }
    this.persistSnapshot(run);

    const iteration = currentIterationForRun(active) ?? 1;
    const retryKey = `${node.id}@${iteration}`;
    const retryMax = this.softEnforcementRetryMax;

    let chainIndex = 0;
    while (true) {
      const currentRunId = chainState.runChain[chainIndex];
      const terminal = await this.runCoordinator.waitForRun(currentRunId, node.timeoutMs ?? undefined);
      if (terminal.status === "interrupted") {
        // A workflow message or external intervention may still be creating a
        // continuation run; wait for the logical chain to receive that distinct id.
        await waitForChainExtension(active, node.id, chainIndex + 2, terminal.id);
      }
      const latestChain = active.agentVertexState.get(node.id)?.runChain ?? chainState.runChain;
      const isLastInChain = chainIndex >= latestChain.length - 1;
      if (terminal.status === "interrupted" && !isLastInChain) {
        // A logical handoff: an h2-message appended a continuation run after interrupting
        // this one. Move to the next run in the chain and continue waiting for terminal.
        this.recordEvent(run, "agent.handed_off", {
          nodeId: node.id,
          interruptedRunId: terminal.id,
          continuationRunId: latestChain[chainIndex + 1]
        });
        chainIndex += 1;
        continue;
      }
      if (terminal.status !== "succeeded") {
        this.recordEvent(run, "vertex.failed", {
          vertexId: vertex.id,
          reason: "agent.terminal_failure",
          runId: terminal.id,
          status: terminal.status
        });
        active.agentVertexState.delete(node.id);
        throw new Error(`agent ${node.id} terminated with status ${terminal.status}`);
      }
      this.recordEvent(run, "agent.terminal", { nodeId: node.id, runId: terminal.id });

      const producerAliases = new Set<string>([vertex.id]);
      for (const chainRunId of latestChain) {
        producerAliases.add(this.runCoordinator.getRun(chainRunId).shortName);
      }
      const missing = node.expects.filter((expectation) =>
        !artifactSatisfiesExpectation(run, iteration, expectation, producerAliases)
      );
      if (missing.length === 0) {
        for (const expectation of node.expects) {
          this.recordEvent(run, "agent.expectation_satisfied", {
            nodeId: node.id,
            artifact: expectation.artifact,
            iteration
          });
        }
        active.agentVertexState.delete(node.id);
        return;
      }

      if (chainState.retryCount >= retryMax) {
        this.recordEvent(run, "vertex.failed", {
          vertexId: vertex.id,
          reason: "agent.expectation_unmet",
          missing: missing.map((expectation) => expectation.artifact),
          retries: chainState.retryCount
        });
        active.agentVertexState.delete(node.id);
        throw new Error(
          `agent ${node.id} exhausted soft-enforcement retries without delivering: ${missing.map((expectation) => expectation.artifact).join(", ")}`
        );
      }

      chainState.retryCount += 1;
      active.agentRetryCounts.set(retryKey, chainState.retryCount);
      const continuationMessage = buildContinuationMessage(missing);
      const lastInChainRunId = latestChain[latestChain.length - 1];
      this.recordEvent(run, "agent.expectation_retry", {
        nodeId: node.id,
        runId: lastInChainRunId,
        attempt: chainState.retryCount,
        missing: missing.map((expectation) => expectation.artifact)
      });
      const continuation = await this.runCoordinator.sendMessage({
        runId: lastInChainRunId,
        message: continuationMessage,
        shortName: `${node.shortName ?? node.id}-retry-${chainState.retryCount}`,
        timeoutMs: node.timeoutMs,
        messageOrigin: {
          kind: "workflow",
          sender: "Flow Manager",
          workflowRunId: run.id,
          workflowVertexId: vertex.id
        }
      });
      const currentState = active.agentVertexState.get(node.id);
      if (currentState !== undefined) {
        currentState.runChain.push(continuation.id);
      }
      run.nodeRunIds[node.id] = continuation.id;
      this.persistSnapshot(run);
      chainIndex = (currentState?.runChain.length ?? 1) - 1;
    }
  }

  private async executeMessage(
    run: WorkflowRunRecord,
    active: ActiveWorkflowRun,
    vertex: Vertex
  ): Promise<void> {
    const node = vertex.node as WorkflowMessageNode;
    const targetState = active.agentVertexState.get(node.target);
    const targetRunId = targetState?.runChain[targetState.runChain.length - 1]
      ?? run.nodeRunIds[node.target];
    if (targetRunId === undefined) {
      throw new Error(`Unknown workflow agent target: ${node.target}`);
    }
    const continuation = await this.runCoordinator.sendMessage({
      runId: targetRunId,
      message: resolvePrompt(active.cartridge, node.promptRef, node.promptText),
      shortName: node.shortName,
      timeoutMs: node.timeoutMs,
      messageOrigin: {
        kind: "workflow",
        sender: "Flow Manager",
        workflowRunId: run.id,
        workflowVertexId: vertex.id
      }
    });
    run.nodeRunIds[node.target] = continuation.id;
    // If the target agent vertex is still inflight (its logical chain is active), append
    // the continuation run id so executeAgent transfers its terminal wait to the new run.
    if (targetState !== undefined) {
      targetState.runChain.push(continuation.id);
    }
    this.recordEvent(run, "agent.message_sent", { target: node.target, runId: continuation.id });
    this.persistSnapshot(run);
  }

  private async executeHuman(
    run: WorkflowRunRecord,
    active: ActiveWorkflowRun,
    vertex: Vertex
  ): Promise<void> {
    const node = vertex.node as WorkflowHumanNode;
    this.recordEvent(run, "human.requested", {
      vertexId: vertex.id,
      prompt: node.promptText,
      artifact: node.artifact
    });
    if (node.artifact === undefined) {
      return;
    }
    await waitForArtifactDelivery(active, node.artifact);
  }

  private async executeAwait(
    run: WorkflowRunRecord,
    active: ActiveWorkflowRun,
    vertex: Vertex
  ): Promise<void> {
    const node = vertex.node as WorkflowAwaitNode;
    this.recordEvent(run, "await.entered", { vertexId: vertex.id, expression: node.on });

    // Record the event-type baseline at the moment the await entered the inflight set.
    // The predicate resolver sees only event types observed after this baseline so that
    // `event.<type>` semantics are scoped to the await-entry window, per the spec.
    const baseline = new Set(active.emittedEventTypes);
    const buildContext = (): PredicateContext => ({
      ...predicateContextFor(active, vertex),
      awaitObservedEventTypes: diffEventTypes(active.emittedEventTypes, baseline)
    });

    const warnings: WorkflowExpressionWarning[] = [];
    if (evaluatePredicate(buildContext(), run, node.on, warnings)) {
      this.emitExpressionWarnings(run, warnings);
      return;
    }
    this.emitExpressionWarnings(run, warnings);

    await new Promise<void>((resolve, reject) => {
      const watcher = () => {
        const watcherWarnings: WorkflowExpressionWarning[] = [];
        if (evaluatePredicate(buildContext(), run, node.on, watcherWarnings)) {
          this.emitExpressionWarnings(run, watcherWarnings);
          active.predicateRevalidators.delete(watcher);
          if (timeout !== undefined) {
            clearTimeout(timeout);
          }
          resolve();
        }
      };
      active.predicateRevalidators.add(watcher);
      let timeout: NodeJS.Timeout | undefined;
      if (node.timeoutMs !== undefined) {
        timeout = setTimeout(() => {
          active.predicateRevalidators.delete(watcher);
          this.recordEvent(run, "vertex.failed", {
            vertexId: vertex.id,
            reason: "await.timeout",
            expression: node.on,
            timeoutMs: node.timeoutMs
          });
          reject(new Error(`h2-await ${vertex.id} timed out after ${node.timeoutMs}ms`));
        }, node.timeoutMs);
      }
    });
  }

  private assertScriptAdapterUsable(uses: string, kind: ScriptAdapterKind): void {
    const descriptor = this.scriptRegistry.get(uses);
    if (descriptor === undefined) {
      throw new Error(`Unknown workflow script adapter: ${uses}`);
    }
    if (!descriptor.kinds.includes(kind)) {
      throw new Error(`Workflow script adapter ${uses} does not support ${kind}`);
    }
    if (this.authorizedScript !== undefined && !this.authorizedScript(uses)) {
      throw new Error(`Unauthorized workflow script adapter: ${uses}`);
    }
  }

  private executeScript(run: WorkflowRunRecord, vertex: Vertex): void {
    const node = vertex.node as { type: "script"; uses: string };
    this.assertScriptAdapterUsable(node.uses, "script");
    this.recordEvent(run, "script.completed", { uses: node.uses });
  }

  private executeCheck(run: WorkflowRunRecord, vertex: Vertex): void {
    const node = vertex.node as { type: "check"; uses: string };
    this.assertScriptAdapterUsable(node.uses, "check");
    this.recordEvent(run, "check.completed", { uses: node.uses });
  }

  private emitExpressionWarnings(run: WorkflowRunRecord, warnings: WorkflowExpressionWarning[]): void {
    for (const warning of warnings) {
      this.recordEvent(run, warning.kind, { artifact: warning.artifactName });
    }
  }

  private executeTransform(run: WorkflowRunRecord, active: ActiveWorkflowRun, vertex: Vertex): void {
    const node = vertex.node as WorkflowTransformNode;
    if (node.uses !== undefined) {
      this.assertScriptAdapterUsable(node.uses, "transform");
    }
    const warnings: WorkflowExpressionWarning[] = [];
    const value = resolvePath(predicateContextFor(active, vertex), run, node.from, warnings);
    this.emitExpressionWarnings(run, warnings);
    const boardMatch = /^board\.([^.]+)$/.exec(node.to);
    let patch: Record<string, unknown> | undefined;
    if (node.uses === "rlcr.initializeGoalTracker") {
      patch = initializeRlcrGoalTrackerBoard(value, {
        cwd: run.cwd,
        graph: active.graph,
        run
      });
    } else if (node.uses === "rlcr.updateLoopStatus") {
      patch = updateRlcrLoopStatusBoard(value, {
        cwd: run.cwd,
        graph: active.graph,
        run,
        loopId: vertex.enclosingLoopId
      });
    }
    const resolvedPatch = patch ?? (value !== undefined && value !== null && typeof value === "object" ? value as Record<string, unknown> : undefined);
    if (boardMatch !== null && resolvedPatch !== undefined) {
      const board = run.boards.find((item) => item.id === boardMatch[1]);
      if (board === undefined) {
        throw new Error(`Unknown board: ${boardMatch[1]}`);
      }
      board.value = {
        ...board.value,
        ...resolvedPatch
      };
      board.updatedAt = this.now();
      notifyBoardWaiters(active);
      notifyPredicateWaiters(active);
    }
    this.recordEvent(run, "transform.completed", {
      id: vertex.id,
      from: node.from,
      to: node.to,
      uses: node.uses
    });
  }

  private async executeSleep(vertex: Vertex): Promise<void> {
    const node = vertex.node as WorkflowSleepNode;
    if (node.durationMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, node.durationMs));
    }
  }

  private routeDownstream(
    run: WorkflowRunRecord,
    active: ActiveWorkflowRun,
    vertex: Vertex,
    chosenEdges: Edge[] | undefined
  ): void {
    const outgoing = active.graph.outgoing.get(vertex.id) ?? [];
    const edges = chosenEdges ?? outgoing;
    for (const edge of edges) {
      this.takeEdge(run, active, edge);
    }
    this.persistSnapshot(run);
  }

  private takeEdge(run: WorkflowRunRecord, active: ActiveWorkflowRun, edge: Edge): void {
    const target = active.graph.vertices.get(edge.to);
    if (target === undefined) {
      throw new Error(`Edge target not found: ${edge.to}`);
    }

    if (target.kind === "parallel-join") {
      const arrivals = (active.joinArrivals.get(target.id) ?? 0) + 1;
      active.joinArrivals.set(target.id, arrivals);
      const incoming = active.graph.incoming.get(target.id) ?? [];
      const expected = incoming.filter((incomingEdge) => incomingEdge.kind === "join").length;
      if (arrivals >= expected) {
        this.enqueueVertex(active, target.id);
      }
      return;
    }

    if (edge.kind === "backedge" || edge.kind === "continue-edge") {
      // Re-entering a loop body. Clear the vertex's completion so it can fire again.
      active.completed.delete(edge.to);
      active.joinArrivals.delete(edge.to);
      this.resetLoopBody(active, edge.to);
    }

    this.enqueueVertex(active, edge.to);
  }

  private resetLoopBody(active: ActiveWorkflowRun, loopEntryId: string): void {
    const loopMeta = active.graph.loops.get(loopEntryId);
    if (loopMeta === undefined) {
      return;
    }
    // Reset every vertex in the compiled loop body, including nested loop entries,
    // nested loop tails, parallel joins, and anonymous synthetic vertices. Also reset
    // join arrivals and per-iteration counters so a nested loop counts from zero again.
    for (const vertexId of loopMeta.bodyVertexIds) {
      active.completed.delete(vertexId);
      active.joinArrivals.delete(vertexId);
      const vertex = active.graph.vertices.get(vertexId);
      if (vertex !== undefined && vertex.kind === "loop-entry" && vertexId !== loopMeta.entryVertexId) {
        active.loopIterations.delete(vertexId);
      }
    }
    // Also clear the outer loop entry itself so it can re-enter
    active.completed.delete(loopMeta.entryVertexId);
    active.joinArrivals.delete(loopMeta.entryVertexId);
  }

  private enqueueVertex(active: ActiveWorkflowRun, vertexId: string): void {
    if (active.inflight.has(vertexId) || active.completed.has(vertexId)) {
      return;
    }
    active.frontier.add(vertexId);
  }

  private updateWaitingFor(run: WorkflowRunRecord, active: ActiveWorkflowRun): void {
    const waitingFor: WorkflowWaitTarget[] = [];
    for (const vertexId of active.inflight) {
      const vertex = active.graph.vertices.get(vertexId);
      if (vertex === undefined) {
        continue;
      }
      if (vertex.kind === "await") {
        const node = vertex.node as WorkflowAwaitNode;
        waitingFor.push({ kind: "predicate", vertex: vertexId, expression: node.on });
      } else if (vertex.kind === "human") {
        const node = vertex.node as WorkflowHumanNode;
        waitingFor.push({
          kind: "human",
          vertex: vertexId,
          prompt: node.promptText,
          artifact: node.artifact,
          schema: node.schema
        });
      } else if (vertex.kind === "agent") {
        const node = vertex.node as WorkflowAgentNode;
        for (const expectation of node.expects) {
          if (!run.artifacts.some((artifact) => artifact.name === expectation.artifact)) {
            waitingFor.push({ kind: "artifact", name: expectation.artifact, vertex: vertexId });
          }
        }
      }
    }
    const sameTargets = sameWaitingTargets(run.waitingFor, waitingFor);
    run.waitingFor = waitingFor;
    const previousStatus = run.status;
    run.status = waitingFor.length === 0 ? "running" : "waiting";
    if (!sameTargets || previousStatus !== run.status) {
      this.options.store?.recordRun(clone(run));
      this.persistSnapshot(run);
    }
  }

  private maybeFinish(run: WorkflowRunRecord, active: ActiveWorkflowRun): void {
    if (!isTerminal(run.status)) {
      return;
    }
    this.activeRuns.delete(run.id);
    active.resolveSettled();
    this.options.store?.recordRun(clone(run));
    this.events.emit(run.id);
  }

  private failRun(run: WorkflowRunRecord, error: unknown): void {
    if (isTerminal(run.status)) {
      return;
    }
    run.status = "failed";
    run.waitingFor = [];
    run.finishedAt = this.now();
    run.error = error instanceof Error ? error.message : String(error);
    this.recordEvent(run, "workflow.failed", { error: run.error });
    const active = this.activeRuns.get(run.id);
    if (active === undefined) {
      return;
    }
    this.activeRuns.delete(run.id);
    active.resolveSettled();
  }

  private requireRun(id: string): WorkflowRunRecord {
    const run = this.runs.get(id);
    if (run === undefined) {
      throw new Error(`Unknown workflow run: ${id}`);
    }
    return run;
  }

  private recordEvent(run: WorkflowRunRecord, type: string, data?: unknown): void {
    const event: WorkflowEventRecord = {
      index: run.events.length,
      timestamp: this.now(),
      type,
      data
    };
    run.events.push(event);
    this.options.store?.recordRun(clone(run));
    this.persistSnapshot(run);
    this.events.emit(run.id);
  }

  private persistSnapshot(run: WorkflowRunRecord): void {
    const store = this.options.store;
    if (store === undefined || store.recordSnapshot === undefined) {
      return;
    }
    const active = this.activeRuns.get(run.id);
    if (active === undefined) {
      return;
    }
    const agentVertexState: Array<[string, { runChain: string[]; retryCount: number }]> = [];
    for (const [nodeId, state] of active.agentVertexState.entries()) {
      agentVertexState.push([nodeId, { runChain: [...state.runChain], retryCount: state.retryCount }]);
    }
    const snapshot: WorkflowSchedulerSnapshot = {
      schemaVersion: "humanize2.workflow.snapshot.v1",
      storageSchemaVersion: "humanize2.workflow.storage.v1",
      runId: run.id,
      cartridgeId: run.cartridgeId,
      frontier: [...active.frontier],
      inflight: [...active.inflight],
      completed: [...active.completed],
      joinArrivals: [...active.joinArrivals.entries()],
      loopIterations: [...active.loopIterations.entries()],
      agentRetryCounts: [...active.agentRetryCounts.entries()],
      agentVertexState,
      pendingHumanRequests: run.waitingFor.filter((target) => target.kind === "human"),
      emittedEventTypes: [...active.emittedEventTypes]
    };
    store.recordSnapshot(snapshot);
  }

  async restoreRun(input: { run: WorkflowRunRecord; cartridge: WorkflowCartridge; snapshot: WorkflowSchedulerSnapshot }): Promise<WorkflowRunRecord> {
    const { run, cartridge, snapshot } = input;
    if (this.runs.has(run.id)) {
      throw new Error(`workflow run already loaded: ${run.id}`);
    }
    if (!this.cartridges.has(cartridge.id)) {
      const graph = compileGraph(cartridge);
      this.cartridges.set(cartridge.id, { cartridge, graph });
    }
    const compiled = this.cartridges.get(cartridge.id)!;

    const restoredRun = normalizeStoredRun(run);
    this.runs.set(restoredRun.id, restoredRun);

    let resolveSettled = () => {};
    const settled = new Promise<void>((resolve) => {
      resolveSettled = resolve;
    });

    let tickScheduled = false;
    const agentVertexState = new Map<string, AgentVertexState>();
    for (const [nodeId, state] of snapshot.agentVertexState ?? []) {
      agentVertexState.set(nodeId, { runChain: [...state.runChain], retryCount: state.retryCount });
    }
    const active: ActiveWorkflowRun = {
      cartridge: compiled.cartridge,
      graph: compiled.graph,
      frontier: new Set(snapshot.frontier),
      inflight: new Set(),
      completed: new Set(snapshot.completed),
      joinArrivals: new Map(snapshot.joinArrivals),
      loopIterations: new Map(snapshot.loopIterations),
      artifactWaiters: new Map(),
      boardWaiters: new Set(),
      predicateWaiters: new Set(),
      predicateRevalidators: new Set(),
      agentRetryCounts: new Map(snapshot.agentRetryCounts),
      emittedEventTypes: new Set(snapshot.emittedEventTypes ?? []),
      awaitEventBaseline: new Map(),
      agentVertexState,
      settled,
      resolveSettled,
      scheduleTick: () => {
        if (tickScheduled) {
          return;
        }
        tickScheduled = true;
        queueMicrotask(() => {
          tickScheduled = false;
          this.tick(restoredRun).catch((error) => {
            this.failRun(restoredRun, error);
          });
        });
      }
    };
    this.activeRuns.set(restoredRun.id, active);

    const agentsToResume: Array<{ vertexId: string; reason?: string }> = [];
    for (const vertexId of snapshot.inflight) {
      const vertex = compiled.graph.vertices.get(vertexId);
      if (vertex === undefined) {
        continue;
      }
      if (vertex.kind === "await" || vertex.kind === "human") {
        active.frontier.add(vertexId);
        active.completed.delete(vertexId);
        continue;
      }
      if (vertex.kind === "agent") {
        const node = vertex.node as WorkflowAgentNode;
        const chainState = agentVertexState.get(node.id);
        const lastRunId = chainState?.runChain[chainState.runChain.length - 1];
        if (lastRunId === undefined) {
          this.recordEvent(restoredRun, "vertex.failed", {
            vertexId,
            reason: "agent.unrecoverable_after_restart",
            detail: "no managed run id was persisted for the in-flight agent vertex"
          });
          this.failRun(restoredRun, new Error(`agent vertex ${vertexId} cannot be recovered after restart`));
          return clone(restoredRun);
        }
        let managedRun;
        try {
          managedRun = this.runCoordinator.getRun(lastRunId);
        } catch {
          managedRun = undefined;
        }
        if (managedRun === undefined) {
          this.recordEvent(restoredRun, "vertex.failed", {
            vertexId,
            reason: "agent.unrecoverable_after_restart",
            runId: lastRunId,
            detail: "managed run record is missing after restart"
          });
          this.failRun(restoredRun, new Error(`agent vertex ${vertexId} cannot be recovered after restart: managed run ${lastRunId} not found`));
          return clone(restoredRun);
        }
        agentsToResume.push({ vertexId });
        active.frontier.add(vertexId);
        active.completed.delete(vertexId);
        continue;
      }
      this.recordEvent(restoredRun, "workflow.restore_dropped_vertex", {
        vertexId,
        kind: vertex.kind,
        reason: "vertex kind not yet restorable in v0.1"
      });
    }

    this.recordEvent(restoredRun, "workflow.restored", {
      snapshotSchema: snapshot.schemaVersion,
      resumedAgents: agentsToResume.map((entry) => entry.vertexId)
    });
    active.scheduleTick();
    return clone(restoredRun);
  }

  /**
   * Compute the validation status for a delivered artifact.
   *
   * v0.1 rules (see spec "Artifact Semantics" -> "Schema Registry"):
   *  - If the cartridge manifest declares schemas but the delivered artifact
   *    has no `schema` name, treat as `manifest-undeclared` (the manifest set
   *    expectations that this delivery did not satisfy).
   *  - If the cartridge declares a schema set and the delivered `schema` name
   *    is not in that set, treat as `schema-mismatch` (manifest soft tier).
   *  - Otherwise consult the registry by schema name:
   *    - registered + validator passes -> `accepted`.
   *    - registered + validator fails -> `schema-mismatch`.
   *    - unregistered -> `manifest-undeclared` (opaque).
   */
  private computeValidationStatus(
    cartridge: WorkflowCartridge | undefined,
    input: DeliverArtifactInput
  ): ArtifactValidationStatus {
    if (cartridge === undefined) {
      return "accepted";
    }
    const declaredSchemas = cartridge.manifest.artifactSchemas;
    if (declaredSchemas.length > 0 && input.schema === undefined) {
      return "manifest-undeclared";
    }
    if (declaredSchemas.length > 0 && input.schema !== undefined && !declaredSchemas.includes(input.schema)) {
      return "schema-mismatch";
    }
    if (input.schema === undefined) {
      return "accepted";
    }
    const outcome = this.schemaRegistry.validate(input.schema, input.content);
    if (outcome.status === "accepted") {
      return "accepted";
    }
    if (outcome.status === "schema-mismatch") {
      return "schema-mismatch";
    }
    return "manifest-undeclared";
  }

  private findActiveAgentHandoff(runId: string): { run: WorkflowRunRecord; active: ActiveWorkflowRun; nodeId: string } | undefined {
    for (const [workflowRunId, active] of this.activeRuns.entries()) {
      const run = this.runs.get(workflowRunId);
      if (run === undefined) {
        continue;
      }
      for (const [nodeId, state] of active.agentVertexState.entries()) {
        if (state.runChain[state.runChain.length - 1] === runId) {
          return { run, active, nodeId };
        }
      }
    }
    return undefined;
  }
}

function visitNodes(nodes: import("./types.js").WorkflowNode[], visitor: (node: import("./types.js").WorkflowNode) => void): void {
  for (const node of nodes) {
    visitor(node);
    if (node.type === "sequence" || node.type === "parallel" || node.type === "loop") {
      visitNodes(node.children, visitor);
    }
  }
}

function isUnderRoot(target: string, root: string): boolean {
  const normalizedTarget = resolvePathFs(target);
  const normalizedRoot = resolvePathFs(root);
  if (normalizedTarget === normalizedRoot) {
    return true;
  }
  return normalizedTarget.startsWith(`${normalizedRoot}/`);
}

function artifactSatisfiesExpectation(
  run: WorkflowRunRecord,
  iteration: number,
  expectation: { artifact: string; schema?: string },
  producerAliases: Set<string>
): boolean {
  return run.artifacts.some((artifact) => {
    if (artifact.name !== expectation.artifact) {
      return false;
    }
    if ((artifact.iteration ?? 1) !== iteration) {
      return false;
    }
    if (artifact.validationStatus !== "accepted") {
      return false;
    }
    if (expectation.schema !== undefined && artifact.schema !== expectation.schema) {
      return false;
    }
    // Producer must match the workflow node id or one of the current run-chain aliases.
    // Allow undefined producer only when no producer was recorded.
    if (artifact.producer !== undefined && !producerAliases.has(artifact.producer)) {
      return false;
    }
    return true;
  });
}

function buildWorkflowInputSnapshots(
  run: WorkflowRunRecord,
  inputs: WorkflowAgentInput[]
): WorkflowAgentInputSnapshot[] {
  return inputs.map((input) => {
    if (input.kind === "artifact") {
      const artifact = latestAcceptedArtifact(run, input.name, input.schema);
      if (artifact === undefined) {
        return {
          kind: "artifact",
          name: input.name,
          schema: input.schema,
          label: input.label,
          optional: input.optional,
          missing: true
        };
      }
      return {
        kind: "artifact",
        name: input.name,
        schema: artifact.schema,
        label: input.label,
        optional: input.optional,
        producer: artifact.producer,
        iteration: artifact.iteration,
        validationStatus: artifact.validationStatus,
        createdAt: artifact.createdAt,
        content: clone(artifact.content)
      };
    }
    const board = run.boards.find((candidate) => candidate.id === input.id);
    if (board === undefined) {
      return {
        kind: "board",
        id: input.id,
        label: input.label,
        optional: input.optional,
        missing: true
      };
    }
    return {
      kind: "board",
      id: input.id,
      schema: board.schema,
      label: input.label,
      optional: input.optional,
      updatedAt: board.updatedAt,
      value: clone(board.value)
    };
  });
}

function latestAcceptedArtifact(
  run: WorkflowRunRecord,
  name: string,
  schema: string | undefined
): ArtifactRecord | undefined {
  for (let index = run.artifacts.length - 1; index >= 0; index -= 1) {
    const artifact = run.artifacts[index];
    if (artifact.name !== name) {
      continue;
    }
    if (artifact.validationStatus !== "accepted") {
      continue;
    }
    if (schema !== undefined && artifact.schema !== schema) {
      continue;
    }
    return artifact;
  }
  return undefined;
}

function buildContinuationMessage(missing: { artifact: string; schema?: string }[]): string {
  const items = missing
    .map((expectation) => expectation.schema !== undefined
      ? `${expectation.artifact} with schema ${expectation.schema}`
      : expectation.artifact)
    .join(", ");
  return `Humanize2 expected artifact ${items} but it was not delivered. Deliver it now via the artifact_deliver tool.`;
}

function waitForArtifactDelivery(active: ActiveWorkflowRun | undefined, name: string): Promise<void> {
  if (active === undefined) {
    return Promise.resolve();
  }
  return new Promise<void>((resolve) => {
    const set = active.artifactWaiters.get(name) ?? new Set<() => void>();
    set.add(resolve);
    active.artifactWaiters.set(name, set);
  });
}

function notifyArtifactWaiters(active: ActiveWorkflowRun | undefined, name: string): void {
  if (active === undefined) {
    return;
  }
  const set = active.artifactWaiters.get(name);
  if (set === undefined) {
    return;
  }
  for (const resolve of [...set]) {
    set.delete(resolve);
    resolve();
  }
  active.artifactWaiters.delete(name);
}

function notifyBoardWaiters(active: ActiveWorkflowRun | undefined): void {
  if (active === undefined) {
    return;
  }
  for (const resolve of [...active.boardWaiters]) {
    active.boardWaiters.delete(resolve);
    resolve();
  }
}

function notifyPredicateWaiters(active: ActiveWorkflowRun | undefined): void {
  if (active === undefined) {
    return;
  }
  for (const watcher of [...active.predicateRevalidators]) {
    watcher();
  }
}

function evaluateLoopGuard(active: ActiveWorkflowRun, run: WorkflowRunRecord, whileExpr: string | undefined, loopId: string): boolean {
  if (whileExpr === undefined) {
    return true;
  }
  return evaluatePredicate({ graph: active.graph, loopIterations: active.loopIterations, currentLoopId: loopId }, run, whileExpr);
}

function predicateContextFor(active: ActiveWorkflowRun, vertex: Vertex): PredicateContext {
  return {
    graph: active.graph,
    loopIterations: active.loopIterations,
    currentLoopId: vertex.enclosingLoopId
  };
}

async function waitForChainExtension(
  active: ActiveWorkflowRun,
  nodeId: string,
  requiredLength: number,
  interruptedRunId: string,
  timeoutMs = 6_000
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const chain = active.agentVertexState.get(nodeId)?.runChain;
    if (chain !== undefined && chain.length >= requiredLength && chain[requiredLength - 1] !== interruptedRunId) {
      return;
    }
    // Yield to the event loop so any pending sendMessage microtasks finish and extend
    // the run chain. setTimeout(0) reliably yields past the current microtask checkpoint;
    // setImmediate alone can starve in tight microtask loops.
    await new Promise<void>((resolve) => setTimeout(resolve, 1));
  }
}

function sameWaitingTargets(left: WorkflowWaitTarget[], right: WorkflowWaitTarget[]): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let index = 0; index < left.length; index += 1) {
    if (JSON.stringify(left[index]) !== JSON.stringify(right[index])) {
      return false;
    }
  }
  return true;
}

function diffEventTypes(current: Set<string>, baseline: Set<string>): Set<string> {
  const observed = new Set<string>();
  for (const type of current) {
    if (!baseline.has(type)) {
      observed.add(type);
    }
  }
  return observed;
}

function currentIterationForRun(active: ActiveWorkflowRun | undefined): number | undefined {
  if (active === undefined) {
    return undefined;
  }
  let deepest: number | undefined;
  for (const vertexId of active.inflight) {
    const vertex = active.graph.vertices.get(vertexId);
    if (vertex?.enclosingLoopId !== undefined) {
      const meta = active.graph.loops.get(vertex.enclosingLoopId);
      if (meta !== undefined) {
        const iteration = active.loopIterations.get(meta.entryVertexId);
        if (iteration !== undefined && (deepest === undefined || iteration > deepest)) {
          deepest = iteration;
        }
      }
    }
  }
  return deepest;
}

function resolvePrompt(cartridge: WorkflowCartridge, promptRef: string | undefined, promptText: string | undefined): string {
  if (promptText !== undefined) {
    return promptText;
  }
  if (promptRef !== undefined) {
    const template = cartridge.templates[promptRef];
    if (template === undefined) {
      throw new Error(`Unknown workflow template: ${promptRef}`);
    }
    return template;
  }
  return "";
}

function addSeenScript(seenScripts: Map<string, Set<ScriptAdapterKind>>, uses: string, kind: ScriptAdapterKind): void {
  const kinds = seenScripts.get(uses) ?? new Set<ScriptAdapterKind>();
  kinds.add(kind);
  seenScripts.set(uses, kinds);
}

function isTerminal(status: string): boolean {
  return status === "succeeded" || status === "failed";
}

function randomId(): string {
  return randomUUID();
}

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

function normalizeDeliveredContent(content: unknown): unknown {
  if (typeof content !== "string") {
    return content;
  }
  const trimmed = content.trim();
  if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) {
    return content;
  }
  try {
    return JSON.parse(trimmed) as unknown;
  } catch {
    return content;
  }
}

function normalizeStoredRun(run: WorkflowRunRecord): WorkflowRunRecord {
  const normalized = clone(run);
  normalized.waitingFor ??= [];
  normalized.nodeRunIds ??= {};
  normalized.boards ??= [];
  normalized.artifacts ??= [];
  normalized.views ??= [];
  normalized.events ??= [];
  normalized.loopIterations ??= {};
  normalized.vars ??= {};
  if (isTerminal(normalized.status)) {
    normalized.waitingFor = [];
  }
  return normalized;
}

type Parse5Element = DefaultTreeAdapterTypes.Element;
type Parse5ChildNode = DefaultTreeAdapterTypes.ChildNode;
type Parse5ParentNode = DefaultTreeAdapterTypes.ParentNode;

function renderViewHtml(html: string, graph: GraphInstance, run: WorkflowRunRecord): string {
  const fragment = parseFragment(html);
  rewriteBindings(fragment as Parse5ParentNode, graph, run);
  return fragment.childNodes.map((child) => serializeOuter(child)).join("");
}

function rewriteBindings(parent: Parse5ParentNode, graph: GraphInstance, run: WorkflowRunRecord): void {
  for (const child of parent.childNodes) {
    if (!isParse5Element(child)) {
      continue;
    }
    const bindAttrIndex = child.attrs.findIndex((attr) => attr.name === "data-h2-bind");
    if (bindAttrIndex !== -1) {
      const path = child.attrs[bindAttrIndex].value;
      const resolved = resolveBindingValue(path, graph, run);
      if (resolved !== undefined && resolved !== null && resolved !== "") {
        child.childNodes = [{
          nodeName: "#text",
          value: formatBindingValue(resolved),
          parentNode: child
        } as DefaultTreeAdapterTypes.TextNode];
      }
    }
    rewriteBindings(child as Parse5ParentNode, graph, run);
  }
}

function resolveBindingValue(path: string, graph: GraphInstance, run: WorkflowRunRecord): unknown {
  const context: PredicateContext = {
    graph,
    loopIterations: new Map(Object.entries(run.loopIterations ?? {})),
    currentLoopId: undefined
  };
  try {
    return resolvePath(context, run, path);
  } catch {
    return undefined;
  }
}

function formatBindingValue(value: unknown): string {
  if (value === undefined || value === null) {
    return "";
  }
  if (typeof value === "string") {
    return value;
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  return JSON.stringify(value);
}

function isParse5Element(node: Parse5ChildNode): node is Parse5Element {
  return "tagName" in node;
}
