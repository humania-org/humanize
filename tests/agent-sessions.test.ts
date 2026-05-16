import { describe, expect, it } from "vitest";

import { buildAgentSessions } from "../src/hub/agent-sessions.js";
import type { AgentRunRecord } from "../src/hub/runs.js";

describe("buildAgentSessions", () => {
  it("folds interrupted run attempts into one user-visible session", () => {
    const runs = [
      run({
        id: "captain-a",
        shortName: "captain-market-team",
        prompt: "start team",
        agent: "codex",
        model: "gpt-5",
        reasoningEffort: "high",
        status: "interrupted",
        startedAt: "2026-05-13T18:00:00.000Z",
        finishedAt: "2026-05-13T18:00:20.000Z",
        durationMs: 20_000,
        backendSessionId: "vendor-captain",
        outputEvents: [
          event("stderr", "[humanize2] intervention message\nchange direction\n", "2026-05-13T18:00:10.000Z"),
          event("stdout", '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":4}}\n')
        ]
      }),
      run({
        id: "worker-1-a",
        shortName: "worker-1-nvda",
        prompt: "lookup NVDA",
        agent: "claude",
        model: "claude-opus-4-7",
        reasoningEffort: "xhigh",
        parentRunId: "captain-b",
        status: "interrupted",
        startedAt: "2026-05-13T18:00:03.000Z",
        finishedAt: "2026-05-13T18:00:12.000Z",
        durationMs: 9_000,
        backendSessionId: "vendor-worker-1",
        outputEvents: [event("stdout", '{"usage":{"input_tokens":3,"output_tokens":2}}\n')]
      }),
      run({
        id: "worker-1-b",
        shortName: "worker-1-msft-intervention",
        prompt: "change to MSFT",
        agent: "claude",
        model: "claude-opus-4-7",
        reasoningEffort: "xhigh",
        parentRunId: "captain-a",
        continuedFromRunId: "worker-1-a",
        interventionMessage: "change to MSFT",
        status: "succeeded",
        startedAt: "2026-05-13T18:00:13.000Z",
        finishedAt: "2026-05-13T18:00:40.000Z",
        durationMs: 27_000,
        backendSessionId: "vendor-worker-1",
        outputEvents: [event("stdout", '{"type":"result","result":"MSFT done"}\n')]
      }),
      run({
        id: "captain-b",
        shortName: "captain-direct-intervention",
        prompt: "change direction",
        agent: "codex",
        model: "gpt-5",
        reasoningEffort: "high",
        continuedFromRunId: "captain-a",
        interventionMessage: "change direction",
        status: "succeeded",
        startedAt: "2026-05-13T18:00:21.000Z",
        finishedAt: "2026-05-13T18:00:55.000Z",
        durationMs: 34_000,
        backendSessionId: "vendor-captain",
        outputEvents: [
          event("stdout", '{"type":"turn.completed","usage":{"input_tokens":8,"output_tokens":6}}\n'),
          event("stdout", '{"type":"result","result":"captain done"}\n')
        ]
      })
    ];

    const sessions = buildAgentSessions(runs, "2026-05-13T18:01:00.000Z");

    expect(sessions).toHaveLength(2);
    expect(sessions.map((session) => session.title)).toEqual(["captain", "worker-1"]);
    expect(sessions[0]).toMatchObject({
      id: "captain-a",
      title: "captain",
      sessionId: "vendor-captain",
      vendorSessionId: "vendor-captain",
      currentRunId: "captain-b",
      previousRunId: "captain-a",
      status: "succeeded",
      agent: "codex",
      model: "gpt-5",
      reasoningEffort: "high",
      modelLabel: "gpt-5 high",
      durationMs: 55_000,
      stats: {
        inputTokens: 18,
        outputTokens: 10,
        totalTokens: 28
      }
    });
    expect(sessions[0].stats.contextWindowTokens).toBe(400_000);
    expect(sessions[0].stats.contextUsedTokens).toBeUndefined();
    expect(sessions[0].stats.contextUsagePercent).toBeUndefined();
    expect(sessions[0].inputHistory).toMatchObject([
      { kind: "prompt", runId: "captain-a", text: "start team" },
      { kind: "intervention", runId: "captain-b", text: "change direction" }
    ]);
    expect(sessions[1]).toMatchObject({
      id: "worker-1-a",
      title: "worker-1",
      sessionId: "vendor-worker-1",
      parentSessionId: "captain-a",
      currentRunId: "worker-1-b",
      previousRunId: "worker-1-a",
      status: "succeeded",
      agent: "claude",
      model: "claude-opus-4-7",
      reasoningEffort: "xhigh",
      modelLabel: "opus-4.7 xhigh",
      stats: {
        inputTokens: 3,
        outputTokens: 2,
        totalTokens: 5
      }
    });
    expect(sessions[1].stats.contextWindowTokens).toBe(1_000_000);
    expect(sessions[1].stats.contextUsedTokens).toBe(3);
    expect(sessions[1].stats.contextUsagePercent).toBeCloseTo(0.0003, 4);
    expect(sessions[1].attempts.map((attempt) => attempt.runId)).toEqual(["worker-1-a", "worker-1-b"]);
    expect(sessions[1].inputHistory.map((entry) => entry.kind)).toEqual(["prompt", "intervention"]);
  });

  it("keeps a captain with no message to a single input entry while workers can be messaged", () => {
    const sessions = buildAgentSessions([
      run({
        id: "captain",
        shortName: "captain-market-team",
        prompt: "create workers through the platform",
        status: "running",
        startedAt: "2026-05-13T18:00:00.000Z",
        finishedAt: undefined,
        durationMs: undefined
      }),
      run({
        id: "worker-a",
        shortName: "worker-1-nvda",
        parentRunId: "captain",
        prompt: "lookup NVDA",
        status: "interrupted",
        startedAt: "2026-05-13T18:00:01.000Z",
        finishedAt: "2026-05-13T18:00:10.000Z",
        durationMs: 9_000
      }),
      run({
        id: "worker-b",
        shortName: "worker-1-msft",
        parentRunId: "captain",
        continuedFromRunId: "worker-a",
        interventionMessage: "change to MSFT",
        prompt: "change to MSFT",
        status: "succeeded",
        startedAt: "2026-05-13T18:00:11.000Z",
        finishedAt: "2026-05-13T18:00:20.000Z",
        durationMs: 9_000
      })
    ], "2026-05-13T18:00:30.000Z");

    expect(sessions.find((session) => session.title === "captain")?.inputHistory).toMatchObject([
      { kind: "prompt", text: "create workers through the platform" }
    ]);
    expect(sessions.find((session) => session.title === "worker-1")?.inputHistory).toMatchObject([
      { kind: "prompt", text: "lookup NVDA" },
      { kind: "intervention", text: "change to MSFT" }
    ]);
  });

  it("keeps workflow-origin intervention metadata for dashboard attribution", () => {
    const sessions = buildAgentSessions([
      run({ id: "captain", shortName: "captain", prompt: "captain", status: "succeeded" }),
      run({
        id: "worker-a",
        shortName: "worker-1",
        parentRunId: "captain",
        prompt: "initial task",
        status: "interrupted"
      }),
      run({
        id: "worker-b",
        shortName: "worker-1-intervention",
        parentRunId: "captain",
        continuedFromRunId: "worker-a",
        interventionMessage: "change task",
        prompt: "change task",
        status: "succeeded",
        messageOrigin: {
          kind: "workflow",
          sender: "Flow Manager",
          workflowRunId: "workflow-run",
          workflowVertexId: "worker-message"
        }
      })
    ], "2026-05-13T18:00:30.000Z");

    const worker = sessions.find((session) => session.title === "worker-1");
    expect(worker?.inputHistory).toContainEqual(expect.objectContaining({
      kind: "intervention",
      text: "change task",
      origin: {
        kind: "workflow",
        sender: "Flow Manager",
        workflowRunId: "workflow-run",
        workflowVertexId: "worker-message"
      }
    }));
  });

  it("uses metadata hints for model labels and context window usage", () => {
    const sessions = buildAgentSessions([
      run({
        id: "codex-run",
        shortName: "codex-default",
        agent: "codex",
        model: undefined,
        backendSessionId: "codex-session",
        outputEvents: [event("stdout", '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}\n')]
      }),
      run({
        id: "claude-run",
        shortName: "claude-stream",
        agent: "claude",
        model: undefined,
        outputEvents: [event("stdout", '{"type":"assistant","message":{"model":"claude-opus-4-7"},"usage":{"input_tokens":2,"output_tokens":1}}\n')]
      })
    ], {
      now: "2026-05-13T18:01:00.000Z",
      metadataByVendorSessionId: {
        "codex-session": {
          model: "gpt-5.5",
          reasoningEffort: "xhigh",
          inputTokens: 7,
          outputTokens: 4,
          cacheReadInputTokens: 20,
          reasoningOutputTokens: 2,
          contextUsedTokens: 120_000,
          contextWindowTokens: 258_400
        }
      },
      agentDefaults: {
        claude: {
          reasoningEffort: "xhigh"
        }
      }
    });

    expect(sessions[0]).toMatchObject({
      model: "gpt-5.5",
      reasoningEffort: "xhigh",
      modelLabel: "gpt-5.5 xhigh",
      stats: {
        inputTokens: 7,
        outputTokens: 4,
        totalTokens: 33,
        cacheReadInputTokens: 20,
        reasoningOutputTokens: 2,
        contextUsedTokens: 120_000,
        contextWindowTokens: 258_400
      }
    });
    expect(sessions[0].stats.contextUsagePercent).toBeCloseTo(46.44, 2);
    expect(sessions[1]).toMatchObject({
      model: "claude-opus-4-7",
      reasoningEffort: "xhigh",
      modelLabel: "opus-4.7 xhigh"
    });
  });

  it("derives latest context load from streamed usage objects", () => {
    const sessions = buildAgentSessions([
      run({
        id: "claude-run",
        shortName: "claude-stream",
        agent: "claude",
        model: "claude-opus-4-7[1m]",
        outputEvents: [
          event("stdout", '{"type":"assistant","message":{"usage":{"input_tokens":6,"cache_creation_input_tokens":100,"cache_read_input_tokens":0,"output_tokens":50}}}\n'),
          event("stdout", '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":20,"cache_read_input_tokens":100,"output_tokens":10}}}\n')
        ]
      })
    ], "2026-05-13T18:01:00.000Z");

    expect(sessions[0].stats).toMatchObject({
      inputTokens: 7,
      cacheCreationInputTokens: 120,
      cacheReadInputTokens: 100,
      outputTokens: 60,
      totalTokens: 287,
      contextUsedTokens: 121,
      contextWindowTokens: 1_000_000
    });
    expect(sessions[0].stats.contextUsagePercent).toBeCloseTo(0.0121, 4);
  });

  it("does not use Codex aggregate turn usage as latest context", () => {
    const sessions = buildAgentSessions([
      run({
        id: "codex-run",
        shortName: "codex-run",
        agent: "codex",
        model: "gpt-5.5",
        outputEvents: [
          event("stdout", '{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":90,"reasoning_output_tokens":30}}\n')
        ]
      })
    ], "2026-05-13T18:01:00.000Z");

    expect(sessions[0].stats).toMatchObject({
      inputTokens: 200,
      cacheReadInputTokens: 800,
      outputTokens: 60,
      reasoningOutputTokens: 30,
      totalTokens: 1090,
      contextWindowTokens: 258_400
    });
    expect(sessions[0].stats.contextUsedTokens).toBeUndefined();
    expect(sessions[0].stats.contextUsagePercent).toBeUndefined();
  });

  it("uses aggregate result usage for totals and message usage for latest context", () => {
    const sessions = buildAgentSessions([
      run({
        id: "claude-run",
        shortName: "claude-stream",
        agent: "claude",
        model: "claude-opus-4-7[1m]",
        outputEvents: [
          event("stdout", '{"type":"assistant","message":{"id":"msg-a","type":"message","usage":{"input_tokens":1,"cache_creation_input_tokens":20,"cache_read_input_tokens":100,"output_tokens":10}}}\n'),
          event("stdout", '{"type":"assistant","message":{"id":"msg-a","type":"message","usage":{"input_tokens":1,"cache_creation_input_tokens":20,"cache_read_input_tokens":100,"output_tokens":10}}}\n'),
          event("stdout", '{"type":"result","usage":{"input_tokens":5,"cache_creation_input_tokens":40,"cache_read_input_tokens":200,"output_tokens":25}}\n')
        ]
      })
    ], "2026-05-13T18:01:00.000Z");

    expect(sessions[0].stats).toMatchObject({
      inputTokens: 5,
      cacheCreationInputTokens: 40,
      cacheReadInputTokens: 200,
      outputTokens: 25,
      totalTokens: 270,
      contextUsedTokens: 121,
      contextWindowTokens: 1_000_000
    });
  });
});

function run(overrides: Partial<AgentRunRecord>): AgentRunRecord {
  return {
    id: "run",
    schemaVersion: "humanize2.run.v1",
    sessionId: "hub-session",
    shortName: "run",
    agent: "codex",
    prompt: "prompt",
    cwd: "/tmp/project",
    timeoutMs: 600_000,
    project: {
      path: "/tmp/project",
      git: {
        isRepo: false
      }
    },
    status: "succeeded",
    createdAt: overrides.startedAt ?? "2026-05-13T18:00:00.000Z",
    startedAt: "2026-05-13T18:00:00.000Z",
    finishedAt: "2026-05-13T18:00:01.000Z",
    durationMs: 1_000,
    outputEvents: [],
    ...overrides
  } as AgentRunRecord;
}

function event(stream: "stdout" | "stderr", text: string, timestamp = "2026-05-13T18:00:01.000Z") {
  return {
    index: 0,
    timestamp,
    stream,
    text
  };
}
