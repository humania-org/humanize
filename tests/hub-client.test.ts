import { describe, expect, it } from "vitest";

import { applyRunEnvironmentDefaults } from "../src/hub-client.js";

describe("hub JSON-RPC client helpers", () => {
  it("fills parentRunId for child spawn requests from the current run environment", () => {
    const params = applyRunEnvironmentDefaults(
      "run.spawn_child",
      {
        agent: "claude",
        prompt: "child task"
      },
      {
        HUMANIZE2_RUN_ID: "parent-run"
      }
    );

    expect(params).toEqual({
      agent: "claude",
      prompt: "child task",
      parentRunId: "parent-run"
    });
  });

  it("does not override an explicit parentRunId", () => {
    const params = applyRunEnvironmentDefaults(
      "run.spawn_child",
      {
        parentRunId: "explicit-parent",
        agent: "codex",
        prompt: "child task"
      },
      {
        HUMANIZE2_RUN_ID: "ambient-parent"
      }
    );

    expect(params).toMatchObject({
      parentRunId: "explicit-parent"
    });
  });

  it("fills runId for send message requests from the current run environment", () => {
    const params = applyRunEnvironmentDefaults(
      "run.send_message",
      {
        message: "change direction"
      },
      {
        HUMANIZE2_RUN_ID: "current-run"
      }
    );

    expect(params).toEqual({
      message: "change direction",
      runId: "current-run",
      messageOrigin: {
        kind: "agent",
        sender: "current-run",
        sourceRunId: "current-run"
      }
    });
  });
});
