#!/usr/bin/env node
import { randomUUID } from "node:crypto";

import { createDefaultBackends } from "./agents/registry.js";
import { loadHumanizeConfig } from "./config.js";
import { createHubHttpServer } from "./hub/http-server.js";
import { AgentRunCoordinator } from "./hub/runs.js";
import { FileRunStore } from "./hub/storage.js";
import { HumanizeService } from "./service.js";
import { WorkflowCoordinator } from "./workflows/coordinator.js";
import { restoreWorkflowRunsFromStore } from "./workflows/recovery.js";
import { FileWorkflowStore } from "./workflows/storage.js";

async function main(): Promise<void> {
  const host = process.env.HUMANIZE2_HOST ?? "127.0.0.1";
  const port = Number.parseInt(process.env.HUMANIZE2_PORT ?? "4772", 10);
  const jsonRpcUrl = process.env.HUMANIZE2_JSONRPC_URL ?? `http://${host}:${port}/jsonrpc`;
  const config = await loadHumanizeConfig();
  const store = await FileRunStore.create({
    stateDir: config.cacheDir,
    sessionId: randomUUID()
  });
  const workflowStore = await FileWorkflowStore.create({
    stateDir: config.cacheDir
  });
  const scriptAllow = config.workflow.scripts.allow;
  const initialRuns = await store.loadRuns();
  const service = new HumanizeService(createDefaultBackends());
  const coordinator = new AgentRunCoordinator(service, {
    jsonRpcUrl,
    store,
    initialRuns,
    defaultRunTimeoutMs: config.defaultRunTimeoutMs,
    agentDefaults: config.agentDefaults
  });
  const workflowCoordinator = new WorkflowCoordinator(coordinator, {
    store: workflowStore,
    softEnforcementRetryMax: config.workflow.softEnforcement.retryMax,
    authorizedScripts: scriptAllow === undefined || scriptAllow.length === 0
      ? undefined
      : (uses) => scriptAllow.includes(uses)
  });
  const workflowRestore = await restoreWorkflowRunsFromStore(workflowStore, workflowCoordinator);
  const server = createHubHttpServer(coordinator, {
    agentDefaults: config.agentDefaults,
    defaultTheme: config.defaultTheme,
    workflowCoordinator
  });

  server.listen(port, host, () => {
    console.error(`Humanize2 hub listening on http://${host}:${port}`);
    console.error(`Humanize2 JSON-RPC endpoint ${jsonRpcUrl}`);
    console.error(`Humanize2 config file ${config.configPath}`);
    console.error(`Humanize2 state directory ${store.stateDir}`);
    console.error(`Humanize2 restored workflows imported=${workflowRestore.imported} active=${workflowRestore.restored} errors=${workflowRestore.errors.length}`);
  });
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.stack ?? error.message : String(error);
  console.error(message);
  process.exit(1);
});
