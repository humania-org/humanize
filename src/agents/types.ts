export type AgentId = "codex" | "claude";

export type SandboxMode = "read-only" | "workspace-write" | "danger-full-access";

export type PermissionMode = "acceptEdits" | "auto" | "bypassPermissions" | "default" | "dontAsk" | "plan";

export type OutputStream = "stdout" | "stderr";

export interface OutputChunk {
  stream: OutputStream;
  text: string;
}

export interface AgentRequest {
  prompt: string;
  cwd?: string;
  model?: string;
  reasoningEffort?: string;
  timeoutMs?: number;
  sandbox?: SandboxMode;
  permissionMode?: PermissionMode;
  extraArgs?: string[];
  env?: Record<string, string>;
  signal?: AbortSignal;
  resumeSessionId?: string;
  onOutput?: (event: OutputChunk) => void;
  /**
   * Populated by the workflow coordinator when this run is spawned by a
   * workflow vertex. Carries the launch-context contract that backends and
   * managed agents may rely on to call back into the hub.
   */
  workflowContext?: WorkflowAgentLaunchContext;
}

/**
 * Stable contract for workflow-spawned agent runs. The fields here describe
 * what the agent needs to call back into Humanize2 (jsonRpcUrl, mcpToolNames)
 * and what the cartridge expects the agent to deliver
 * (workflowRunId, vertexId, expectedArtifacts). See the spec section
 * "MCP and JSON-RPC Surface" -> "Agent Launch Context".
 */
export interface WorkflowAgentLaunchContext {
  workflowRunId: string;
  vertexId: string;
  shortName: string;
  jsonRpcUrl: string;
  expectedArtifacts: ReadonlyArray<{ name: string; schema?: string }>;
  inputs?: ReadonlyArray<WorkflowAgentInputSnapshot>;
  mcpToolNames: readonly string[];
}

export type WorkflowAgentInputSnapshot =
  | WorkflowAgentArtifactInputSnapshot
  | WorkflowAgentBoardInputSnapshot;

export interface WorkflowAgentArtifactInputSnapshot {
  kind: "artifact";
  name: string;
  schema?: string;
  label?: string;
  optional: boolean;
  missing?: boolean;
  producer?: string;
  iteration?: number;
  validationStatus?: string;
  createdAt?: string;
  content?: unknown;
}

export interface WorkflowAgentBoardInputSnapshot {
  kind: "board";
  id: string;
  schema?: string;
  label?: string;
  optional: boolean;
  missing?: boolean;
  updatedAt?: string;
  value?: unknown;
}

export interface AgentResult {
  agent: AgentId;
  success: boolean;
  exitCode: number | null;
  signal: NodeJS.Signals | null;
  stdout: string;
  stderr: string;
  durationMs: number;
  timedOut: boolean;
  command: string;
  args: string[];
  cwd?: string;
  backendSessionId?: string;
  events?: unknown[];
}

export interface AgentStatus {
  agent: AgentId;
  displayName: string;
  available: boolean;
  version?: string;
  error?: string;
}

export interface CommandPlan {
  command: string;
  args: string[];
  cwd?: string;
  env?: Record<string, string>;
  timeoutMs?: number;
  signal?: AbortSignal;
  onOutput?: (event: OutputChunk) => void;
}

export interface CommandResult {
  exitCode: number | null;
  signal: NodeJS.Signals | null;
  stdout: string;
  stderr: string;
  durationMs: number;
  timedOut: boolean;
}

export interface CommandRunner {
  run(plan: CommandPlan): Promise<CommandResult>;
}

export interface AgentBackend {
  readonly id: AgentId;
  readonly displayName: string;
  status(): Promise<AgentStatus>;
  run(request: AgentRequest): Promise<AgentResult>;
}
