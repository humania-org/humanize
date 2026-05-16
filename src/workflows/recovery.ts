import type { WorkflowCoordinator } from "./coordinator.js";
import type { WorkflowCartridge, WorkflowRunRecord, WorkflowSchedulerSnapshot } from "./types.js";

export interface RestorableWorkflowStore {
  loadRuns(): Promise<WorkflowRunRecord[]>;
  loadSnapshot(runId: string): Promise<WorkflowSchedulerSnapshot | undefined>;
  loadCartridgeHtml(cartridgeId: string): Promise<string | undefined>;
}

export interface WorkflowRestoreReport {
  imported: number;
  restored: number;
  errors: Array<{ runId: string; message: string }>;
}

export async function restoreWorkflowRunsFromStore(
  store: RestorableWorkflowStore,
  coordinator: WorkflowCoordinator
): Promise<WorkflowRestoreReport> {
  const report: WorkflowRestoreReport = {
    imported: 0,
    restored: 0,
    errors: []
  };

  for (const run of await store.loadRuns()) {
    const cartridge = await loadStoredCartridge(store, coordinator, run, report);
    const snapshot = await loadStoredSnapshot(store, run, report);
    if (!isWorkflowTerminal(run) && cartridge !== undefined && snapshot !== undefined) {
      try {
        await coordinator.restoreRun({ run, cartridge, snapshot });
        report.restored += 1;
        continue;
      } catch (error) {
        report.errors.push({ runId: run.id, message: errorMessage(error) });
      }
    }
    coordinator.loadStoredRun({ run, cartridge });
    report.imported += 1;
  }

  return report;
}

async function loadStoredCartridge(
  store: RestorableWorkflowStore,
  coordinator: WorkflowCoordinator,
  run: WorkflowRunRecord,
  report: WorkflowRestoreReport
): Promise<WorkflowCartridge | undefined> {
  const html = await store.loadCartridgeHtml(run.cartridgeId);
  if (html === undefined) {
    report.errors.push({ runId: run.id, message: `Missing workflow cartridge: ${run.cartridgeId}` });
    return undefined;
  }
  try {
    return await coordinator.loadHtml({ html });
  } catch (error) {
    report.errors.push({ runId: run.id, message: errorMessage(error) });
    return undefined;
  }
}

async function loadStoredSnapshot(
  store: RestorableWorkflowStore,
  run: WorkflowRunRecord,
  report: WorkflowRestoreReport
): Promise<WorkflowSchedulerSnapshot | undefined> {
  try {
    return await store.loadSnapshot(run.id);
  } catch (error) {
    report.errors.push({ runId: run.id, message: errorMessage(error) });
    return undefined;
  }
}

function isWorkflowTerminal(run: WorkflowRunRecord): boolean {
  return run.status === "succeeded" || run.status === "failed";
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
