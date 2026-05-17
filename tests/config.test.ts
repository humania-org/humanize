import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { afterEach, describe, expect, it } from "vitest";

import { DEFAULT_RUN_TIMEOUT_MS, loadHumanizeConfig } from "../src/config.js";

const tempDirs: string[] = [];

afterEach(async () => {
  await Promise.all(tempDirs.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

async function tempDirectory(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "humanize2-config-"));
  tempDirs.push(directory);
  return directory;
}

describe("humanize2 user config", () => {
  it("creates a day-one user config under the home h2 directory", async () => {
    const home = await tempDirectory();

    const config = await loadHumanizeConfig({}, home);

    expect(config.configPath).toBe(join(home, ".h2", "config.yaml"));
    expect(config.cacheDir).toBe(join(home, ".h2", "cache"));
    expect(config.defaultRunTimeoutMs).toBe(DEFAULT_RUN_TIMEOUT_MS);
    expect(config.defaultTheme).toBe("dark");

    const contents = await readFile(config.configPath, "utf8");
    expect(contents).toContain("cacheDir:");
    expect(contents).toContain("defaultRunTimeoutMs:");
    expect(contents).toContain("defaultTheme: dark");
    expect(contents).toContain("agents:");
    expect(config.agentDefaults.codex).toMatchObject({
      model: "gpt-5.5",
      reasoningEffort: "xhigh"
    });
  });

  it("honors config file and environment overrides", async () => {
    const home = await tempDirectory();
    const configPath = join(home, "custom-config.yaml");

    await loadHumanizeConfig({ HUMANIZE2_CONFIG: configPath }, home);

    const config = await loadHumanizeConfig({
      HUMANIZE2_CONFIG: configPath,
      HUMANIZE2_CACHE_DIR: "/tmp/humanize2-cache",
      HUMANIZE2_DEFAULT_TIMEOUT_MS: "12345"
    }, home);

    expect(config.configPath).toBe(configPath);
    expect(config.cacheDir).toBe("/tmp/humanize2-cache");
    expect(config.defaultRunTimeoutMs).toBe(12_345);
  });

  it("loads per-agent model fallback settings from the user config", async () => {
    const home = await tempDirectory();
    const configPath = join(home, "custom-config.yaml");

    await loadHumanizeConfig({ HUMANIZE2_CONFIG: configPath }, home);
    const contents = [
      "version: 1",
      "cacheDir: /tmp/humanize2-cache",
      "defaultRunTimeoutMs: 12345",
      "defaultTheme: light",
      "agents:",
      "  codex:",
      "    model: gpt-5.4",
      "    reasoningEffort: high",
      "  claude:",
      "    model: claude-opus-4-7",
      "    reasoningEffort: xhigh",
      ""
    ].join("\n");
    await writeFile(configPath, contents, "utf8");

    const config = await loadHumanizeConfig({ HUMANIZE2_CONFIG: configPath }, home);

    expect(config.agentDefaults).toEqual({
      codex: {
        model: "gpt-5.4",
        reasoningEffort: "high"
      },
      claude: {
        model: "claude-opus-4-7",
        reasoningEffort: "xhigh"
      }
    });
    expect(config.defaultTheme).toBe("light");
  });

  it("loads agent model fields after a prior agent's multiline extraArgs list", async () => {
    const home = await tempDirectory();
    const configPath = join(home, "multiline-extraargs-config.yaml");

    const contents = [
      "version: 1",
      "cacheDir: /tmp/humanize2-cache",
      "defaultRunTimeoutMs: 12345",
      "defaultTheme: dark",
      "agents:",
      "  codex:",
      "    model: gpt-5.4",
      "    extraArgs:",
      "      - --temperature",
      "      - 0.7",
      "      - --max-tokens",
      "      - 4096",
      "  claude:",
      "    model: claude-opus-4-7",
      "    reasoningEffort: xhigh",
      ""
    ].join("\n");
    await writeFile(configPath, contents, "utf8");

    const config = await loadHumanizeConfig({ HUMANIZE2_CONFIG: configPath }, home);

    expect(config.agentDefaults.codex).toMatchObject({
      model: "gpt-5.4",
      extraArgs: ["--temperature", "0.7", "--max-tokens", "4096"]
    });
    expect(config.agentDefaults.claude).toMatchObject({
      model: "claude-opus-4-7",
      reasoningEffort: "xhigh"
    });
  });

  it("loads sibling fields after empty extraArgs under the same agent", async () => {
    const home = await tempDirectory();
    const configPath = join(home, "sibling-after-extraargs-config.yaml");

    const contents = [
      "version: 1",
      "cacheDir: /tmp/humanize2-cache",
      "defaultRunTimeoutMs: 12345",
      "defaultTheme: dark",
      "agents:",
      "  codex:",
      "    extraArgs: []",
      "    model: gpt-5.5",
      "    reasoningEffort: xhigh",
      ""
    ].join("\n");
    await writeFile(configPath, contents, "utf8");

    const config = await loadHumanizeConfig({ HUMANIZE2_CONFIG: configPath }, home);

    expect(config.agentDefaults.codex).toMatchObject({
      model: "gpt-5.5",
      reasoningEffort: "xhigh",
      extraArgs: []
    });
  });

  it("loads workflow retry and script allowlist settings from the user config", async () => {
    const home = await tempDirectory();
    const configPath = join(home, "workflow-config.yaml");

    await writeFile(configPath, [
      "version: 1",
      "cacheDir: /tmp/humanize2-cache",
      "defaultRunTimeoutMs: 12345",
      "defaultTheme: dark",
      "workflow:",
      "  softEnforcement:",
      "    retryMax: 5",
      "  scripts:",
      "    allow:",
      "      - test.pass",
      "      - git.statusClean",
      "agents:",
      "  codex:",
      "    model: gpt-5.5",
      "    reasoningEffort: xhigh",
      "  claude:",
      "    model: claude-opus-4-7",
      "    reasoningEffort: xhigh",
      ""
    ].join("\n"), "utf8");

    const config = await loadHumanizeConfig({ HUMANIZE2_CONFIG: configPath }, home);

    expect((config as any).workflow).toEqual({
      softEnforcement: { retryMax: 5 },
      scripts: { allow: ["test.pass", "git.statusClean"] }
    });
  });
});
