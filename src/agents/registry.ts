import { createClaudeBackend } from "./claude.js";
import { NodeCommandRunner } from "./cli.js";
import { createCodexBackend } from "./codex.js";
import { createFakeBackend } from "./fake.js";
import type { AgentBackend, CommandRunner } from "./types.js";

export function createDefaultBackends(
  env: NodeJS.ProcessEnv = process.env,
  runner: CommandRunner = new NodeCommandRunner()
): AgentBackend[] {
  const fakeResponse = env.HUMANIZE2_FAKE_AGENT_RESPONSE;

  if (fakeResponse !== undefined) {
    const fakeDelayMs = Number.parseInt(env.HUMANIZE2_FAKE_AGENT_DELAY_MS ?? "0", 10);
    const delayMs = Number.isFinite(fakeDelayMs) && fakeDelayMs > 0 ? fakeDelayMs : 0;

    return [
      createFakeBackend("codex", fakeResponse, delayMs),
      createFakeBackend("claude", fakeResponse, delayMs)
    ];
  }

  return [
    createCodexBackend(runner),
    createClaudeBackend(runner)
  ];
}
