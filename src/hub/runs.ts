import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";

import { extractBackendSessionIdFromText } from "../agents/json-lines.js";
import type { AgentId, AgentRequest, AgentResult, OutputStream } from "../agents/types.js";
import { DEFAULT_RUN_TIMEOUT_MS, type AgentModelDefaultsByAgent } from "../config.js";
import type { AgentStatusInput, AgentStatusResult, HumanizeService, RunAgentInput } from "../service.js";
import { collectProjectMetadata, deriveShortName, type RunProjectMetadata } from "./run-metadata.js";
import { RUN_SCHEMA_VERSION, type FileRunStore, type RunSessionRecord } from "./storage.js";

export type AgentRunStatus = "running" | "succeeded" | "failed" | "interrupted";

export interface AgentRunRecord {
  id: string;
  schemaVersion: typeof RUN_SCHEMA_VERSION;
  sessionId: string;
  shortName: string;
  parentRunId?: string;
  continuedFromRunId?: string;
  interventionMessage?: string;
  messageOrigin?: AgentMessageOrigin;
  backendSessionId?: string;
  agent: AgentId;
  model?: string;
  reasoningEffort?: string;
  prompt: string;
  cwd?: string;
  timeoutMs: number;
  project: RunProjectMetadata;
  status: AgentRunStatus;
  createdAt: string;
  startedAt?: string;
  finishedAt?: string;
  durationMs?: number;
  outputEvents: AgentRunOutputEvent[];
  result?: AgentResult;
  error?: string;
}

export interface AgentMessageOrigin {
  kind: "user" | "agent" | "workflow";
  sender?: string;
  sourceRunId?: string;
  workflowRunId?: string;
  workflowVertexId?: string;
}

export interface AgentRunOutputEvent {
  index: number;
  timestamp: string;
  stream: OutputStream;
  text: string;
}

export interface AgentRunCoordinatorOptions {
  jsonRpcUrl: string;
  idFactory?: () => string;
  sessionId?: string;
  store?: FileRunStore;
  initialRuns?: AgentRunRecord[];
  defaultRunTimeoutMs?: number;
  agentDefaults?: AgentModelDefaultsByAgent;
}

export interface CreateRunOptions {
  parentRunId?: string;
  continuedFromRunId?: string;
  interventionMessage?: string;
  messageOrigin?: AgentMessageOrigin;
}

export interface SendMessageInput {
  runId: string;
  message: string;
  shortName?: string;
  timeoutMs?: number;
  interrupt?: boolean;
  messageOrigin?: AgentMessageOrigin;
}

interface ActiveRun {
  controller: AbortController;
  finishedRecorded: boolean;
  settled: Promise<void>;
  resolveSettled: () => void;
}

type StoredRunInput = Omit<RunAgentInput, "onOutput">;

type ContinuationBase = Pick<
  RunAgentInput,
  "agent" | "cwd" | "model" | "reasoningEffort" | "sandbox" | "permissionMode" | "extraArgs" | "env" | "workflowContext"
>;

export class AgentRunCoordinator {
  private readonly runs = new Map<string, AgentRunRecord>();
  private readonly activeRuns = new Map<string, ActiveRun>();
  private readonly runInputs = new Map<string, StoredRunInput>();
  private readonly events = new EventEmitter();
  private readonly idFactory: () => string;
  private readonly sessionId: string;

  constructor(
    private readonly service: HumanizeService,
    private readonly options: AgentRunCoordinatorOptions
  ) {
    this.idFactory = options.idFactory ?? randomUUID;
    this.sessionId = options.store?.sessionId ?? options.sessionId ?? randomUUID();
    for (const run of options.initialRuns ?? []) {
      this.runs.set(run.id, cloneRun(run));
    }
  }

  async agentStatus(input: AgentStatusInput): Promise<AgentStatusResult> {
    return this.service.agentStatus(input);
  }

  /**
   * JSON-RPC URL that managed runs are configured to call back into. Workflow
   * launch contexts surface this so workflow-spawned agents can reach the hub.
   */
  get jsonRpcUrl(): string {
    return this.options.jsonRpcUrl;
  }

  createRun(input: RunAgentInput, options: CreateRunOptions = {}): AgentRunRecord {
    if (options.parentRunId !== undefined && !this.runs.has(options.parentRunId)) {
      throw new Error(`Unknown parent run: ${options.parentRunId}`);
    }
    if (options.continuedFromRunId !== undefined && !this.runs.has(options.continuedFromRunId)) {
      throw new Error(`Unknown continued run: ${options.continuedFromRunId}`);
    }

    const parentRun = options.parentRunId === undefined ? undefined : this.runs.get(options.parentRunId);
    const parentInput = options.parentRunId === undefined ? undefined : this.runInputs.get(options.parentRunId);
    const shortName = input.shortName ?? deriveShortName(input.prompt);
    const inheritedWorkflowContext = parentInput?.workflowContext === undefined
      ? undefined
      : {
        ...cloneWorkflowContext(parentInput.workflowContext),
        vertexId: shortName,
        shortName,
        expectedArtifacts: []
      };
    const defaults = this.options.agentDefaults?.[input.agent] ?? {};
    const effectiveInput: RunAgentInput = {
      ...input,
      model: input.model ?? defaults.model,
      reasoningEffort: input.reasoningEffort ?? defaults.reasoningEffort,
      permissionMode: input.permissionMode ?? defaults.permissionMode,
      sandbox: input.sandbox ?? defaults.sandbox,
      extraArgs: input.extraArgs ?? defaults.extraArgs,
      cwd: input.cwd ?? parentRun?.cwd,
      workflowContext: input.workflowContext ?? inheritedWorkflowContext
    };
    const id = this.idFactory();
    const timestamp = new Date().toISOString();
    const timeoutMs = effectiveInput.timeoutMs ?? this.options.defaultRunTimeoutMs ?? DEFAULT_RUN_TIMEOUT_MS;
    const storedInput = storeRunInput({
      ...effectiveInput,
      timeoutMs
    });
    const record: AgentRunRecord = {
      id,
      schemaVersion: RUN_SCHEMA_VERSION,
      sessionId: this.sessionId,
      shortName,
      parentRunId: options.parentRunId,
      continuedFromRunId: options.continuedFromRunId,
      interventionMessage: options.interventionMessage,
      messageOrigin: options.messageOrigin === undefined ? undefined : { ...options.messageOrigin },
      agent: effectiveInput.agent,
      model: effectiveInput.model,
      reasoningEffort: effectiveInput.reasoningEffort,
      prompt: effectiveInput.prompt,
      cwd: effectiveInput.cwd,
      timeoutMs,
      project: collectProjectMetadata(effectiveInput.cwd),
      status: "running",
      createdAt: timestamp,
      startedAt: timestamp,
      outputEvents: []
    };

    this.runs.set(id, record);
    this.runInputs.set(id, storedInput);
    let resolveSettled = () => {};
    const settled = new Promise<void>((resolve) => {
      resolveSettled = resolve;
    });
    this.activeRuns.set(id, {
      controller: new AbortController(),
      finishedRecorded: false,
      settled,
      resolveSettled
    });
    this.options.store?.recordRunCreated(cloneRun(record));
    this.emitChange(id);
    void this.execute(record, effectiveInput);

    return cloneRun(record);
  }

  getRun(id: string): AgentRunRecord {
    const record = this.runs.get(id);
    if (record === undefined) {
      throw new Error(`Unknown run: ${id}`);
    }

    return cloneRun(record);
  }

  listRuns(): AgentRunRecord[] {
    return [...this.runs.values()].map(cloneRun);
  }

  listSessions(): RunSessionRecord[] {
    return this.options.store?.listSessions() ?? [];
  }

  inferActiveParentRunId(input: Pick<RunAgentInput, "cwd">): string {
    const candidates = [...this.activeRuns.keys()]
      .map((id) => this.runs.get(id))
      .filter((run): run is AgentRunRecord => run !== undefined && run.status === "running")
      .filter((run) => input.cwd === undefined || run.cwd === input.cwd);

    if (candidates.length === 1) {
      return candidates[0].id;
    }

    if (candidates.length === 0) {
      throw new Error("parentRunId is required because no running Humanize2 run could be inferred");
    }

    throw new Error("parentRunId is required because multiple running Humanize2 runs match the request");
  }

  async sendMessage(input: SendMessageInput): Promise<AgentRunRecord> {
    if (input.message.length === 0) {
      throw new Error("message must be a non-empty string");
    }

    const target = this.runs.get(input.runId);
    if (target === undefined) {
      throw new Error(`Unknown run: ${input.runId}`);
    }

    const shouldInterrupt = input.interrupt ?? true;
    let interruptedRun: ActiveRun | undefined;
    if (target.status === "running" && shouldInterrupt) {
      interruptedRun = this.activeRuns.get(target.id);
      this.interruptRun(target, input.message);
    } else {
      this.recordInterventionEvent(target, input.message);
    }

    if (interruptedRun !== undefined) {
      await waitForSettled(interruptedRun.settled, 5_000);
    }

    const base = this.continuationBaseFor(target);
    const run = this.createRun(
      {
        ...base,
        prompt: input.message,
        shortName: input.shortName ?? deriveShortName(input.message),
        timeoutMs: input.timeoutMs ?? target.timeoutMs,
        resumeSessionId: target.backendSessionId
      },
      {
        parentRunId: target.parentRunId,
        continuedFromRunId: target.id,
        interventionMessage: input.message,
        messageOrigin: input.messageOrigin
      }
    );

    return run;
  }

  async waitForRun(id: string, timeoutMs = 600_000): Promise<AgentRunRecord> {
    const current = this.getRun(id);
    if (isTerminal(current.status)) {
      return current;
    }

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.events.off(id, onChange);
        reject(new Error(`Timed out waiting for run: ${id}`));
      }, timeoutMs);

      const onChange = () => {
        const record = this.getRun(id);
        if (!isTerminal(record.status)) {
          return;
        }

        clearTimeout(timeout);
        this.events.off(id, onChange);
        resolve(record);
      };

      this.events.on(id, onChange);
    });
  }

  private async execute(record: AgentRunRecord, input: RunAgentInput): Promise<void> {
    const startedAt = Date.now();
    const active = this.activeRuns.get(record.id);
    const signal = active?.controller.signal;

    try {
      const result = await this.service.runAgent({
        ...input,
        timeoutMs: record.timeoutMs,
        resumeSessionId: input.resumeSessionId,
        signal,
        env: this.buildRunEnvironment(record, input.env),
        onOutput: (event) => {
          this.recordOutput(record, event.stream, event.text);
          input.onOutput?.(event);
          this.emitChange(record.id);
        }
      });
      if (record.status === "interrupted") {
        return;
      }
      record.backendSessionId = result.backendSessionId ?? record.backendSessionId;
      record.result = result;
      record.status = result.success ? "succeeded" : "failed";
      if (!result.success) {
        record.error = result.stderr || `Agent exited with status ${result.exitCode ?? "unknown"}`;
      }
    } catch (error) {
      if (record.status === "interrupted") {
        return;
      }
      record.status = "failed";
      record.error = error instanceof Error ? error.message : String(error);
    } finally {
      if (record.status !== "interrupted") {
        record.finishedAt = new Date().toISOString();
        record.durationMs = Date.now() - startedAt;
      }
      if (active !== undefined && !active.finishedRecorded) {
        active.finishedRecorded = true;
        this.options.store?.recordRunFinished(cloneRun(record));
      }
      active?.resolveSettled();
      this.activeRuns.delete(record.id);
      this.emitChange(record.id);
    }
  }

  private interruptRun(record: AgentRunRecord, message: string): void {
    const active = this.activeRuns.get(record.id);
    this.recordInterventionEvent(record, message);
    record.status = "interrupted";
    record.error = "Interrupted by Humanize2 message";
    record.finishedAt = new Date().toISOString();
    record.durationMs = Date.parse(record.finishedAt) - Date.parse(record.startedAt ?? record.createdAt);

    if (active !== undefined) {
      active.finishedRecorded = true;
      active.controller.abort();
    }

    this.options.store?.recordRunFinished(cloneRun(record));
    this.emitChange(record.id);
  }

  private recordInterventionEvent(record: AgentRunRecord, message: string): void {
    this.recordOutput(record, "stderr", `[humanize2] intervention message\n${message}\n`);
  }

  private recordOutput(record: AgentRunRecord, stream: OutputStream, text: string): void {
    record.backendSessionId ??= extractBackendSessionIdFromText(text);
    const outputEvent = {
      index: record.outputEvents.length,
      timestamp: new Date().toISOString(),
      stream,
      text
    };
    record.outputEvents.push(outputEvent);
    this.options.store?.recordRunOutput(record.id, outputEvent);
  }

  private continuationBaseFor(record: AgentRunRecord): ContinuationBase {
    const stored = this.runInputs.get(record.id);
    if (stored !== undefined) {
      return {
        agent: stored.agent,
        cwd: stored.cwd,
        model: stored.model,
        reasoningEffort: stored.reasoningEffort,
        sandbox: stored.sandbox,
        permissionMode: stored.permissionMode,
        extraArgs: stored.extraArgs === undefined ? undefined : [...stored.extraArgs],
        env: stored.env === undefined ? undefined : { ...stored.env },
        workflowContext: stored.workflowContext === undefined ? undefined : cloneWorkflowContext(stored.workflowContext)
      };
    }

    return {
      agent: record.agent,
      cwd: record.cwd
    };
  }

  private buildRunEnvironment(record: AgentRunRecord, requestEnvironment: AgentRequest["env"]): Record<string, string> {
    return {
      ...requestEnvironment,
      HUMANIZE2_JSONRPC_URL: this.options.jsonRpcUrl,
      HUMANIZE2_RUN_ID: record.id,
      HUMANIZE2_RUN_SHORT_NAME: record.shortName,
      HUMANIZE2_RUN_TIMEOUT_MS: String(record.timeoutMs),
      ...(record.model === undefined ? {} : { HUMANIZE2_RUN_MODEL: record.model }),
      ...(record.reasoningEffort === undefined ? {} : { HUMANIZE2_RUN_REASONING_EFFORT: record.reasoningEffort }),
      ...(record.parentRunId === undefined ? {} : { HUMANIZE2_PARENT_RUN_ID: record.parentRunId }),
      ...(record.continuedFromRunId === undefined ? {} : { HUMANIZE2_CONTINUED_FROM_RUN_ID: record.continuedFromRunId })
    };
  }

  private emitChange(id: string): void {
    this.events.emit(id);
    this.events.emit("change");
  }
}

function isTerminal(status: AgentRunStatus): boolean {
  return status === "succeeded" || status === "failed" || status === "interrupted";
}

function storeRunInput(input: RunAgentInput): StoredRunInput {
  const { onOutput: _onOutput, ...stored } = input;
  return {
    ...stored,
    extraArgs: stored.extraArgs === undefined ? undefined : [...stored.extraArgs],
    env: stored.env === undefined ? undefined : { ...stored.env },
    workflowContext: stored.workflowContext === undefined ? undefined : cloneWorkflowContext(stored.workflowContext)
  };
}

async function waitForSettled(settled: Promise<void>, timeoutMs: number): Promise<void> {
  let timeout: NodeJS.Timeout | undefined;
  await Promise.race([
    settled,
    new Promise<void>((resolve) => {
      timeout = setTimeout(resolve, timeoutMs);
    })
  ]);
  if (timeout !== undefined) {
    clearTimeout(timeout);
  }
}

function cloneRun(record: AgentRunRecord): AgentRunRecord {
  return {
    ...record,
    messageOrigin: record.messageOrigin === undefined ? undefined : { ...record.messageOrigin },
    outputEvents: record.outputEvents.map((event) => ({ ...event })),
    result: record.result === undefined ? undefined : {
      ...record.result,
      args: [...record.result.args],
      events: record.result.events === undefined ? undefined : [...record.result.events]
    }
  };
}

function cloneWorkflowContext(context: NonNullable<RunAgentInput["workflowContext"]>): NonNullable<RunAgentInput["workflowContext"]> {
  return {
    ...context,
    expectedArtifacts: context.expectedArtifacts.map((artifact) => ({ ...artifact })),
    inputs: context.inputs === undefined ? undefined : cloneJson(context.inputs),
    mcpToolNames: [...context.mcpToolNames]
  };
}

function cloneJson<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}
