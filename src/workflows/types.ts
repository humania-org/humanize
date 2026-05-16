import type { AgentId } from "../agents/types.js";

export type WorkflowRunStatus = "running" | "waiting" | "succeeded" | "failed";

export interface WorkflowCartridge {
  id: string;
  name: string;
  version?: string;
  schema?: string;
  sourceHtml: string;
  sourcePath?: string;
  manifest: WorkflowManifest;
  boards: WorkflowBoardDefinition[];
  eventTypes: WorkflowEventDefinition[];
  artifactTypes: WorkflowArtifactDefinition[];
  templates: Record<string, string>;
  vars: WorkflowVarDefinition[];
  views: WorkflowViewDefinition[];
  nodes: WorkflowNode[];
  loadEvents: WorkflowEventRecord[];
}

export interface WorkflowManifest {
  agentTools: string[];
  scriptAllowlist: string[];
  artifactSchemas: string[];
  declaresView: boolean;
  declaresHumanInput: boolean;
}

export interface WorkflowVarDefinition {
  name: string;
  value: string;
}

export interface WorkflowBoardDefinition {
  id: string;
  schema?: string;
}

export interface WorkflowEventDefinition {
  type: string;
}

export interface WorkflowArtifactDefinition {
  name: string;
  schema?: string;
}

export interface WorkflowViewDefinition {
  slot: string;
  html: string;
}

export interface WorkflowDashboardProjection {
  flow: WorkflowFlowProjection;
}

export interface WorkflowFlowProjection {
  nodes: WorkflowFlowProjectionNode[];
}

export interface WorkflowFlowProjectionNode {
  id: string;
  kind: WorkflowNode["type"];
  label: string;
  status: "pending" | "running" | "completed" | "failed";
  children?: WorkflowFlowProjectionNode[];
  loop?: {
    iteration: number;
    max: number;
    while?: string;
    counterLabel?: string;
  };
  branch?: {
    on: string;
    cases: WorkflowFlowProjectionBranchCase[];
    defaultTarget: string;
  };
  agent?: {
    tool: AgentId;
    role?: string;
    shortName?: string;
    inputs?: WorkflowAgentInput[];
  };
  script?: {
    uses: string;
  };
  transform?: {
    from: string;
    to: string;
    uses?: string;
  };
  await?: {
    on: string;
  };
  human?: {
    artifact?: string;
    schema?: string;
  };
  message?: {
    target: string;
    shortName?: string;
  };
  sleep?: {
    durationMs: number;
  };
}

export interface WorkflowFlowProjectionBranchCase {
  value: string;
  goto?: string;
  continueLoop?: string;
}

export type WorkflowNode =
  | WorkflowSequenceNode
  | WorkflowParallelNode
  | WorkflowLoopNode
  | WorkflowScriptNode
  | WorkflowCheckNode
  | WorkflowAgentNode
  | WorkflowMessageNode
  | WorkflowSleepNode
  | WorkflowAwaitNode
  | WorkflowBranchNode
  | WorkflowHumanNode
  | WorkflowTransformNode
  | WorkflowEndNode;

export interface WorkflowEndNode {
  type: "end";
  id?: string;
}

export interface WorkflowSequenceNode {
  type: "sequence";
  id?: string;
  children: WorkflowNode[];
}

export interface WorkflowParallelNode {
  type: "parallel";
  id?: string;
  children: WorkflowNode[];
}

export interface WorkflowLoopNode {
  type: "loop";
  id: string;
  while?: string;
  max: number;
  counterLabel?: string;
  children: WorkflowNode[];
}

export interface WorkflowScriptNode {
  type: "script";
  id?: string;
  uses: string;
}

export interface WorkflowCheckNode {
  type: "check";
  id?: string;
  uses: string;
}

export interface WorkflowAgentNode {
  type: "agent";
  id: string;
  tool: AgentId;
  role?: string;
  parent?: string;
  promptRef?: string;
  promptText?: string;
  shortName?: string;
  timeoutMs?: number;
  inputs: WorkflowAgentInput[];
  expects: WorkflowExpectation[];
  hooks: WorkflowHookDefinition[];
}

export type WorkflowAgentInput =
  | WorkflowAgentArtifactInput
  | WorkflowAgentBoardInput;

export interface WorkflowAgentArtifactInput {
  kind: "artifact";
  name: string;
  schema?: string;
  label?: string;
  optional: boolean;
}

export interface WorkflowAgentBoardInput {
  kind: "board";
  id: string;
  label?: string;
  optional: boolean;
}

export interface WorkflowMessageNode {
  type: "message";
  id?: string;
  target: string;
  promptRef?: string;
  promptText?: string;
  shortName?: string;
  timeoutMs?: number;
}

export interface WorkflowSleepNode {
  type: "sleep";
  id?: string;
  durationMs: number;
}

export interface WorkflowAwaitNode {
  type: "await";
  id?: string;
  on: string;
  timeoutMs?: number;
}

export interface WorkflowExpectation {
  artifact: string;
  schema?: string;
}

export interface WorkflowHookDefinition {
  kind: "soft";
  on?: string;
  artifact?: string;
  schema?: string;
}

export interface WorkflowBranchNode {
  type: "branch";
  id?: string;
  on: string;
  cases: WorkflowCase[];
  defaultTarget: string;
}

export interface WorkflowCase {
  value: string;
  goto?: string;
  continueLoop?: string;
}

export interface WorkflowHumanNode {
  type: "human";
  id?: string;
  promptRef?: string;
  promptText?: string;
  artifact?: string;
  schema?: string;
}

export interface WorkflowTransformNode {
  type: "transform";
  id?: string;
  from: string;
  to: string;
  uses?: string;
}

// ============================================================================
// Compiled graph types (built from WorkflowCartridge by compileGraph)
// ============================================================================

export type VertexKind =
  | "start"
  | "end"
  | "sequence"
  | "parallel-fork"
  | "parallel-join"
  | "loop-entry"
  | "loop-tail"
  | "branch"
  | "await"
  | "agent"
  | "message"
  | "human"
  | "script"
  | "check"
  | "transform"
  | "sleep"
  | "end-marker";

export interface Vertex {
  id: string;
  kind: VertexKind;
  node?: WorkflowNode;
  enclosingLoopId?: string;
}

export type EdgeKind = "fallthrough" | "fork" | "join" | "branch" | "branch-default" | "backedge" | "continue-edge";

export interface Edge {
  id: string;
  from: string;
  to: string;
  kind: EdgeKind;
  matchValue?: string;
  loopId?: string;
}

export interface LoopMetadata {
  loopVertexId: string;
  entryVertexId: string;
  tailVertexId: string;
  parentLoopId?: string;
  bodyVertexIds: string[];
  max: number;
  whileExpr?: string;
}

export interface GraphInstance {
  vertices: Map<string, Vertex>;
  edges: Map<string, Edge>;
  outgoing: Map<string, Edge[]>;
  incoming: Map<string, Edge[]>;
  startVertexId: string;
  endVertexId: string;
  loops: Map<string, LoopMetadata>;
}

// ============================================================================
// Runtime records
// ============================================================================

export interface WorkflowRunRecord {
  id: string;
  cartridgeId: string;
  cartridgeName: string;
  cwd?: string;
  agentToolOverride?: AgentId;
  status: WorkflowRunStatus;
  createdAt: string;
  startedAt?: string;
  finishedAt?: string;
  error?: string;
  waitingFor: WorkflowWaitTarget[];
  nodeRunIds: Record<string, string>;
  boards: BoardRecord[];
  artifacts: ArtifactRecord[];
  views: WorkflowViewDefinition[];
  projection?: WorkflowDashboardProjection;
  events: WorkflowEventRecord[];
  loopIterations: Record<string, number>;
  vars: Record<string, string>;
}

export type WorkflowWaitTarget =
  | { kind: "artifact"; name: string; vertex?: string }
  | { kind: "human"; vertex: string; prompt?: string; artifact?: string; schema?: string }
  | { kind: "predicate"; vertex: string; expression: string };

export interface WorkflowEventRecord {
  index: number;
  timestamp: string;
  type: string;
  message?: string;
  data?: unknown;
}

export type ArtifactValidationStatus = "accepted" | "schema-mismatch" | "manifest-undeclared";

export interface ArtifactRecord {
  id: string;
  workflowRunId: string;
  name: string;
  schema?: string;
  producer?: string;
  iteration?: number;
  content: unknown;
  createdAt: string;
  validationStatus: ArtifactValidationStatus;
}

export interface BoardRecord {
  id: string;
  schema?: string;
  value: Record<string, unknown>;
  updatedAt: string;
}

export interface LoadWorkflowHtmlInput {
  html?: string;
  path?: string;
  sourcePath?: string;
}

export interface StartWorkflowInput {
  cartridgeId: string;
  cwd?: string;
  agentToolOverride?: AgentId;
}

export interface DeliverArtifactInput {
  workflowRunId: string;
  name: string;
  schema?: string;
  producer?: string;
  content: unknown;
}

export interface GetArtifactInput {
  workflowRunId: string;
  name: string;
}

export interface PatchBoardInput {
  workflowRunId: string;
  boardId: string;
  patch: Record<string, unknown>;
}

export interface GetBoardInput {
  workflowRunId: string;
  boardId: string;
}

export interface WorkflowSchedulerSnapshot {
  schemaVersion: "humanize2.workflow.snapshot.v1";
  storageSchemaVersion: "humanize2.workflow.storage.v1";
  runId: string;
  cartridgeId: string;
  frontier: string[];
  inflight: string[];
  completed: string[];
  joinArrivals: Array<[string, number]>;
  loopIterations: Array<[string, number]>;
  agentRetryCounts: Array<[string, number]>;
  agentVertexState: Array<[string, { runChain: string[]; retryCount: number }]>;
  pendingHumanRequests: WorkflowWaitTarget[];
  emittedEventTypes: string[];
}
