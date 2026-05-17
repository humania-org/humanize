import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

import type { AgentId, PermissionMode, SandboxMode } from "./agents/types.js";

export const DEFAULT_RUN_TIMEOUT_MS = 6 * 60 * 60 * 1000;
export const DEFAULT_DASHBOARD_THEME: DashboardTheme = "dark";

export type DashboardTheme = "light" | "dark";

export interface AgentModelDefaults {
  model?: string;
  reasoningEffort?: string;
  permissionMode?: PermissionMode;
  sandbox?: SandboxMode;
  extraArgs?: string[];
}

export type AgentModelDefaultsByAgent = Partial<Record<AgentId, AgentModelDefaults>>;

export interface HumanizeConfig {
  configPath: string;
  cacheDir: string;
  defaultRunTimeoutMs: number;
  defaultTheme: DashboardTheme;
  agentDefaults: AgentModelDefaultsByAgent;
  workflow: WorkflowConfig;
}

export interface WorkflowConfig {
  softEnforcement: {
    retryMax: number;
  };
  scripts: {
    allow?: string[];
  };
}

export const DEFAULT_AGENT_MODEL_DEFAULTS: AgentModelDefaultsByAgent = {
  codex: {
    model: "gpt-5.5",
    reasoningEffort: "xhigh"
  },
  claude: {
    model: "claude-opus-4-7",
    reasoningEffort: "xhigh"
  }
};

export const DEFAULT_WORKFLOW_CONFIG: WorkflowConfig = {
  softEnforcement: {
    retryMax: 3
  },
  scripts: {}
};

export async function loadHumanizeConfig(
  env: NodeJS.ProcessEnv = process.env,
  home = homedir()
): Promise<HumanizeConfig> {
  return loadHumanizeConfigSync(env, home);
}

export function loadHumanizeConfigSync(
  env: NodeJS.ProcessEnv = process.env,
  home = homedir()
): HumanizeConfig {
  const configPath = env.HUMANIZE2_CONFIG && env.HUMANIZE2_CONFIG.length > 0
    ? env.HUMANIZE2_CONFIG
    : join(home, ".h2", "config.yaml");
  const defaultCacheDir = join(home, ".h2", "cache");

  ensureConfigFile(configPath, defaultCacheDir);

  const fileConfig = parseSimpleYaml(readFileSync(configPath, "utf8"));
  const cacheDir = env.HUMANIZE2_CACHE_DIR && env.HUMANIZE2_CACHE_DIR.length > 0
    ? env.HUMANIZE2_CACHE_DIR
    : fileConfig.cacheDir ?? defaultCacheDir;
  const defaultRunTimeoutMs = parsePositiveInteger(
    env.HUMANIZE2_DEFAULT_TIMEOUT_MS,
    fileConfig.defaultRunTimeoutMs ?? DEFAULT_RUN_TIMEOUT_MS
  );
  const defaultTheme = parseTheme(fileConfig.defaultTheme, DEFAULT_DASHBOARD_THEME);
  const agentDefaults = mergeAgentDefaults(DEFAULT_AGENT_MODEL_DEFAULTS, fileConfig.agentDefaults);
  const workflow = mergeWorkflowConfig(DEFAULT_WORKFLOW_CONFIG, fileConfig.workflow);

  return {
    configPath,
    cacheDir,
    defaultRunTimeoutMs,
    defaultTheme,
    agentDefaults,
    workflow
  };
}

function ensureConfigFile(configPath: string, cacheDir: string): void {
  if (existsSync(configPath)) {
    const contents = readFileSync(configPath, "utf8");
    const missingBlocks: string[] = [];
    if (!/^\s*defaultTheme\s*:/m.test(contents)) {
      missingBlocks.push(`defaultTheme: ${DEFAULT_DASHBOARD_THEME}`);
    }
    if (!/^\s*agents\s*:/m.test(contents)) {
      missingBlocks.push(agentDefaultsYamlBlock());
    }
    if (!/^\s*workflow\s*:/m.test(contents)) {
      missingBlocks.push(workflowYamlBlock());
    }
    if (missingBlocks.length > 0) {
      writeFileSync(configPath, `${contents.trimEnd()}\n${missingBlocks.join("\n")}\n`, "utf8");
    }
    return;
  }

  mkdirSync(dirname(configPath), { recursive: true });
  writeFileSync(
    configPath,
    [
      "version: 1",
      `cacheDir: ${cacheDir}`,
      `defaultRunTimeoutMs: ${DEFAULT_RUN_TIMEOUT_MS}`,
      `defaultTheme: ${DEFAULT_DASHBOARD_THEME}`,
      workflowYamlBlock().trimEnd(),
      agentDefaultsYamlBlock().trimEnd(),
      ""
    ].join("\n"),
    "utf8"
  );
}

function agentDefaultsYamlBlock(): string {
  return [
    "agents:",
    "  codex:",
    `    model: ${DEFAULT_AGENT_MODEL_DEFAULTS.codex?.model ?? ""}`,
    `    reasoningEffort: ${DEFAULT_AGENT_MODEL_DEFAULTS.codex?.reasoningEffort ?? ""}`,
    "  claude:",
    `    model: ${DEFAULT_AGENT_MODEL_DEFAULTS.claude?.model ?? ""}`,
    `    reasoningEffort: ${DEFAULT_AGENT_MODEL_DEFAULTS.claude?.reasoningEffort ?? ""}`
  ].join("\n");
}

function workflowYamlBlock(): string {
  return [
    "workflow:",
    "  softEnforcement:",
    `    retryMax: ${DEFAULT_WORKFLOW_CONFIG.softEnforcement.retryMax}`,
    "  scripts:",
    "    allow: []"
  ].join("\n");
}

function parseSimpleYaml(
  contents: string
): Partial<Pick<HumanizeConfig, "cacheDir" | "defaultRunTimeoutMs" | "defaultTheme" | "agentDefaults" | "workflow">> {
  const values: Partial<Pick<HumanizeConfig, "cacheDir" | "defaultRunTimeoutMs" | "defaultTheme" | "agentDefaults" | "workflow">> = {
    agentDefaults: {}
  };
  let section: "agents" | "workflow" | "workflow.softEnforcement" | "workflow.scripts" | "workflow.scripts.allow" | "agents.extraArgs" | undefined;
  let currentAgent: AgentId | undefined;

  for (const line of contents.split("\n")) {
    const trimmedRight = line.trimEnd();
    const trimmed = trimmedRight.trim();
    if (trimmed.length === 0 || trimmed.startsWith("#")) {
      continue;
    }

    const indent = trimmedRight.length - trimmedRight.trimStart().length;
    if (section === "workflow.scripts.allow" && indent >= 6 && trimmed.startsWith("-")) {
      const item = trimmed.slice(1).trim().replace(/^["']|["']$/g, "");
      if (item.length > 0) {
        const workflow = values.workflow ?? cloneWorkflowConfig(DEFAULT_WORKFLOW_CONFIG);
        workflow.scripts.allow = [...(workflow.scripts.allow ?? []), item];
        values.workflow = workflow;
      }
      continue;
    }

    // agent extraArgs list items (e.g., `  - --skip-git-repo-check`)
    if (section === "agents.extraArgs" && indent >= 6 && currentAgent !== undefined && trimmed.startsWith("- ")) {
      const item = trimmed.slice(2).trim().replace(/^["']|["']$/g, "");
      if (item.length > 0) {
        const defaults = values.agentDefaults?.[currentAgent] ?? {};
        defaults.extraArgs = [...(defaults.extraArgs ?? []), item];
        values.agentDefaults = {
          ...values.agentDefaults,
          [currentAgent]: defaults
        };
      }
      continue;
    }

    // extraArgs list is done — reset section so sibling fields (model,
    // permissionMode, sandbox) under the same agent are not silently ignored
    if (section === "agents.extraArgs" && indent >= 4 && currentAgent !== undefined && !trimmed.startsWith("- ")) {
      section = "agents";
    }

    const separatorIndex = trimmed.indexOf(":");
    if (separatorIndex < 0) {
      continue;
    }

    const key = trimmed.slice(0, separatorIndex).trim();
    const value = trimmed.slice(separatorIndex + 1).trim().replace(/^["']|["']$/g, "");
    if (key === "cacheDir" && value.length > 0) {
      values.cacheDir = value;
    }
    if (key === "defaultRunTimeoutMs") {
      values.defaultRunTimeoutMs = parsePositiveInteger(value, DEFAULT_RUN_TIMEOUT_MS);
    }
    if (key === "defaultTheme") {
      values.defaultTheme = parseTheme(value, DEFAULT_DASHBOARD_THEME);
    }
    if (indent === 0) {
      section = key === "agents" ? "agents" : key === "workflow" ? "workflow" : undefined;
      currentAgent = undefined;
      if (section === "agents") {
        continue;
      }
      if (section === "workflow") {
        continue;
      }
    }
    if (
      (section === "workflow" ||
        section === "workflow.softEnforcement" ||
        section === "workflow.scripts" ||
        section === "workflow.scripts.allow") &&
      indent === 2
    ) {
      if (key === "softEnforcement") {
        section = "workflow.softEnforcement";
      } else if (key === "scripts") {
        section = "workflow.scripts";
      }
      continue;
    }
    if (section === "workflow.softEnforcement" && indent >= 4 && key === "retryMax") {
      const workflow = values.workflow ?? cloneWorkflowConfig(DEFAULT_WORKFLOW_CONFIG);
      workflow.softEnforcement.retryMax = parsePositiveInteger(value, DEFAULT_WORKFLOW_CONFIG.softEnforcement.retryMax);
      values.workflow = workflow;
      continue;
    }
    if (section === "workflow.scripts" && indent >= 4 && key === "allow") {
      const workflow = values.workflow ?? cloneWorkflowConfig(DEFAULT_WORKFLOW_CONFIG);
      if (value === "[]" || value.length === 0) {
        workflow.scripts.allow = value === "[]" ? [] : workflow.scripts.allow;
      } else {
        workflow.scripts.allow = parseCommaList(value);
      }
      values.workflow = workflow;
      section = "workflow.scripts.allow";
      continue;
    }
    if ((section === "agents" || section === "agents.extraArgs") && indent === 2) {
      currentAgent = key === "codex" || key === "claude" ? key : undefined;
      section = "agents";
      continue;
    }
    if (section === "agents" && indent >= 4 && currentAgent !== undefined && value.length > 0) {
      const defaults = values.agentDefaults?.[currentAgent] ?? {};
      if (key === "model") {
        defaults.model = value;
      }
      if (key === "reasoningEffort") {
        defaults.reasoningEffort = value;
      }
      if (key === "permissionMode") {
        defaults.permissionMode = value as PermissionMode;
      }
      if (key === "sandbox") {
        defaults.sandbox = value as SandboxMode;
      }
      values.agentDefaults = {
        ...values.agentDefaults,
        [currentAgent]: defaults
      };
    }
    if (section === "agents" && indent >= 4 && currentAgent !== undefined && key === "extraArgs") {
      const defaults = values.agentDefaults?.[currentAgent] ?? {};
      if (value === "[]" || value.length === 0) {
        defaults.extraArgs = [];
        section = "agents.extraArgs";
      } else {
        defaults.extraArgs = parseCommaList(value);
      }
      values.agentDefaults = {
        ...values.agentDefaults,
        [currentAgent]: defaults
      };
    }
  }

  return values;
}

function mergeAgentDefaults(
  defaults: AgentModelDefaultsByAgent,
  overrides: AgentModelDefaultsByAgent | undefined
): AgentModelDefaultsByAgent {
  return {
    codex: {
      ...defaults.codex,
      ...overrides?.codex,
      extraArgs: overrides?.codex?.extraArgs ?? defaults.codex?.extraArgs
    },
    claude: {
      ...defaults.claude,
      ...overrides?.claude,
      extraArgs: overrides?.claude?.extraArgs ?? defaults.claude?.extraArgs
    }
  };
}

function cloneWorkflowConfig(value: WorkflowConfig): WorkflowConfig {
  return {
    softEnforcement: { ...value.softEnforcement },
    scripts: {
      allow: value.scripts.allow === undefined ? undefined : [...value.scripts.allow]
    }
  };
}

function mergeWorkflowConfig(defaults: WorkflowConfig, overrides: WorkflowConfig | undefined): WorkflowConfig {
  return {
    softEnforcement: {
      retryMax: overrides?.softEnforcement.retryMax ?? defaults.softEnforcement.retryMax
    },
    scripts: {
      allow: overrides?.scripts.allow === undefined ? defaults.scripts.allow : [...overrides.scripts.allow]
    }
  };
}

function parseCommaList(value: string): string[] {
  const stripped = value.replace(/^\[|\]$/g, "");
  return stripped.split(",").map((item) => item.trim().replace(/^["']|["']$/g, "")).filter((item) => item.length > 0);
}

function parsePositiveInteger(value: string | number | undefined, fallback: number): number {
  if (value === undefined || value === "") {
    return fallback;
  }

  const parsed = typeof value === "number" ? value : Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function parseTheme(value: string | undefined, fallback: DashboardTheme): DashboardTheme {
  return value === "light" || value === "dark" ? value : fallback;
}
