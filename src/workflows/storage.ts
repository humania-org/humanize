import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import type { WorkflowCartridge, WorkflowRunRecord, WorkflowSchedulerSnapshot } from "./types.js";

const WORKFLOW_STORAGE_SCHEMA_VERSION = "humanize2.workflow.storage.v1";

export interface WorkflowStore {
  recordCartridge(cartridge: WorkflowCartridge): void;
  recordRun(record: WorkflowRunRecord): void;
  recordSnapshot(snapshot: WorkflowSchedulerSnapshot): void;
}

export interface FileWorkflowStoreOptions {
  stateDir: string;
}

export interface RestorableWorkflow {
  cartridge: WorkflowCartridge;
  run: WorkflowRunRecord;
  snapshot?: WorkflowSchedulerSnapshot;
}

export class FileWorkflowStore implements WorkflowStore {
  private constructor(private readonly stateDir: string) {}

  static async create(options: FileWorkflowStoreOptions): Promise<FileWorkflowStore> {
    const store = new FileWorkflowStore(options.stateDir);
    mkdirSync(store.cartridgesDir, { recursive: true });
    mkdirSync(store.runsDir, { recursive: true });
    mkdirSync(store.snapshotsDir, { recursive: true });
    return store;
  }

  recordCartridge(cartridge: WorkflowCartridge): void {
    mkdirSync(this.cartridgesDir, { recursive: true });
    writeFileSync(join(this.cartridgesDir, `${cartridge.id}.html`), cartridge.sourceHtml, "utf8");
    writeFileSync(
      join(this.cartridgesDir, `${cartridge.id}.json`),
      JSON.stringify({
        id: cartridge.id,
        name: cartridge.name,
        version: cartridge.version,
        schema: cartridge.schema,
        sourcePath: cartridge.sourcePath
      }, null, 2),
      "utf8"
    );
  }

  recordRun(record: WorkflowRunRecord): void {
    mkdirSync(this.runsDir, { recursive: true });
    writeFileSync(join(this.runsDir, `${record.id}.json`), JSON.stringify(record, null, 2), "utf8");
  }

  recordSnapshot(snapshot: WorkflowSchedulerSnapshot): void {
    mkdirSync(this.snapshotsDir, { recursive: true });
    writeFileSync(join(this.snapshotsDir, `${snapshot.runId}.json`), JSON.stringify(snapshot, null, 2), "utf8");
  }

  async loadRuns(): Promise<WorkflowRunRecord[]> {
    if (!existsSync(this.runsDir)) {
      return [];
    }
    return readdirSync(this.runsDir, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith(".json"))
      .map((entry) => JSON.parse(readFileSync(join(this.runsDir, entry.name), "utf8")) as WorkflowRunRecord)
      .sort((left, right) => left.createdAt.localeCompare(right.createdAt));
  }

  async loadSnapshot(runId: string): Promise<WorkflowSchedulerSnapshot | undefined> {
    const path = join(this.snapshotsDir, `${runId}.json`);
    if (!existsSync(path)) {
      return undefined;
    }
    const snapshot = JSON.parse(readFileSync(path, "utf8")) as WorkflowSchedulerSnapshot;
    if (snapshot.storageSchemaVersion !== WORKFLOW_STORAGE_SCHEMA_VERSION) {
      throw new Error(`Unsupported workflow storage schema: ${String(snapshot.storageSchemaVersion)}`);
    }
    return snapshot;
  }

  async loadCartridgeHtml(cartridgeId: string): Promise<string | undefined> {
    const sourceHtml = this.loadCurrentSourceHtml(cartridgeId);
    if (sourceHtml !== undefined) {
      return sourceHtml;
    }
    const bundledHtml = this.loadBundledSourceHtml(cartridgeId);
    if (bundledHtml !== undefined) {
      return bundledHtml;
    }
    const path = join(this.cartridgesDir, `${cartridgeId}.html`);
    if (!existsSync(path)) {
      return undefined;
    }
    return readFileSync(path, "utf8");
  }

  private loadCurrentSourceHtml(cartridgeId: string): string | undefined {
    const metadataPath = join(this.cartridgesDir, `${cartridgeId}.json`);
    if (!existsSync(metadataPath)) {
      return undefined;
    }
    try {
      const metadata = JSON.parse(readFileSync(metadataPath, "utf8")) as { sourcePath?: unknown };
      if (typeof metadata.sourcePath !== "string" || metadata.sourcePath.length === 0) {
        return undefined;
      }
      if (!existsSync(metadata.sourcePath)) {
        return undefined;
      }
      return readFileSync(metadata.sourcePath, "utf8");
    } catch {
      return undefined;
    }
  }

  private loadBundledSourceHtml(cartridgeId: string): string | undefined {
    if (!isSafeCartridgeDirectoryName(cartridgeId)) {
      return undefined;
    }
    const sourcePath = join(process.cwd(), "flow", cartridgeId, "workflow.html");
    if (!existsSync(sourcePath)) {
      return undefined;
    }
    return readFileSync(sourcePath, "utf8");
  }

  private get cartridgesDir(): string {
    return join(this.stateDir, "workflows", "cartridges");
  }

  private get runsDir(): string {
    return join(this.stateDir, "workflows", "runs");
  }

  private get snapshotsDir(): string {
    return join(this.stateDir, "workflows", "snapshots");
  }
}

function isSafeCartridgeDirectoryName(value: string): boolean {
  return value.length > 0 && !value.includes("/") && !value.includes("\\") && !value.includes("..");
}
