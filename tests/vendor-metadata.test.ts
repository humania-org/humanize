import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { describe, expect, it } from "vitest";

import { loadVendorSessionMetadataForRuns } from "../src/hub/vendor-metadata.js";
import type { AgentRunRecord } from "../src/hub/runs.js";

describe("vendor session metadata", () => {
  it("reads Codex token counts, cache, reasoning, and latest context load", async () => {
    const home = await tempHome();
    const sessionDir = join(home, ".codex", "sessions", "2026", "05", "13");
    await mkdir(sessionDir, { recursive: true });
    await writeFile(join(sessionDir, "rollout-2026-05-13T00-00-00-codex-session.jsonl"), [
      json({ timestamp: "2026-05-13T18:00:00.000Z", type: "turn_context", payload: { model: "gpt-5.5", effort: "xhigh" } }),
      json({ timestamp: "2026-05-13T18:00:01.000Z", type: "event_msg", payload: { type: "task_started", model_context_window: 258400 } }),
      json({
        timestamp: "2026-05-13T18:00:02.000Z",
        type: "event_msg",
        payload: {
          type: "token_count",
          info: {
            total_token_usage: {
              input_tokens: 1_000,
              cached_input_tokens: 400,
              output_tokens: 90,
              reasoning_output_tokens: 30
            },
            last_token_usage: {
              input_tokens: 700,
              cached_input_tokens: 250,
              output_tokens: 40,
              reasoning_output_tokens: 10
            },
            model_context_window: 258400
          }
        }
      }),
      json({
        timestamp: "2026-05-13T18:00:03.000Z",
        type: "event_msg",
        payload: {
          type: "token_count",
          info: {
            total_token_usage: {
              input_tokens: 1_500,
              cached_input_tokens: 700,
              output_tokens: 160,
              reasoning_output_tokens: 60
            },
            last_token_usage: {
              input_tokens: 900,
              cached_input_tokens: 300,
              output_tokens: 50,
              reasoning_output_tokens: 10
            },
            model_context_window: 258400
          }
        }
      })
    ].join("\n"));

    const metadata = loadVendorSessionMetadataForRuns([run("codex", "codex-session")], home);

    expect(metadata["codex-session"]).toMatchObject({
      model: "gpt-5.5",
      reasoningEffort: "xhigh",
      inputTokens: 800,
      cacheReadInputTokens: 700,
      outputTokens: 100,
      reasoningOutputTokens: 60,
      contextUsedTokens: 900,
      contextWindowTokens: 258400
    });
  });

  it("deduplicates Claude usage records and reads latest context load", async () => {
    const home = await tempHome();
    const projectDir = join(home, ".claude", "projects", "-tmp-project");
    await mkdir(projectDir, { recursive: true });
    await writeFile(join(projectDir, "claude-session.jsonl"), [
      json({
        timestamp: "2026-05-13T18:00:00.000Z",
        requestId: "req-a",
        type: "assistant",
        message: {
          id: "msg-a",
          model: "claude-opus-4-7",
          usage: {
            input_tokens: 6,
            cache_creation_input_tokens: 100,
            cache_read_input_tokens: 0,
            output_tokens: 50
          }
        }
      }),
      json({
        timestamp: "2026-05-13T18:00:01.000Z",
        requestId: "req-a",
        type: "assistant",
        message: {
          id: "msg-a",
          model: "claude-opus-4-7",
          usage: {
            input_tokens: 6,
            cache_creation_input_tokens: 100,
            cache_read_input_tokens: 0,
            output_tokens: 50
          }
        }
      }),
      json({
        timestamp: "2026-05-13T18:00:02.000Z",
        requestId: "req-b",
        type: "assistant",
        message: {
          id: "msg-b",
          model: "claude-opus-4-7",
          usage: {
            input_tokens: 1,
            cache_creation_input_tokens: 20,
            cache_read_input_tokens: 100,
            output_tokens: 10
          }
        }
      })
    ].join("\n"));

    const metadata = loadVendorSessionMetadataForRuns([run("claude", "claude-session")], home);

    expect(metadata["claude-session"]).toMatchObject({
      model: "claude-opus-4-7",
      inputTokens: 7,
      cacheCreationInputTokens: 120,
      cacheReadInputTokens: 100,
      outputTokens: 60,
      contextUsedTokens: 121
    });
  });
});

async function tempHome(): Promise<string> {
  const directory = join(tmpdir(), `humanize2-vendor-${process.pid}-${Math.random().toString(16).slice(2)}`);
  await mkdir(directory, { recursive: true });
  return directory;
}

function run(agent: "codex" | "claude", backendSessionId: string): AgentRunRecord {
  return {
    id: `${agent}-run`,
    schemaVersion: "humanize2.run.v1",
    sessionId: "hub-session",
    shortName: `${agent} run`,
    agent,
    prompt: "prompt",
    cwd: "/tmp/project",
    timeoutMs: 600_000,
    project: {
      path: "/tmp/project",
      git: {
        isRepo: false
      }
    },
    status: "running",
    createdAt: "2026-05-13T18:00:00.000Z",
    startedAt: "2026-05-13T18:00:00.000Z",
    backendSessionId,
    outputEvents: []
  };
}

function json(value: unknown): string {
  return JSON.stringify(value);
}
