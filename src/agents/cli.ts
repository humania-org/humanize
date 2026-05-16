import { spawn } from "node:child_process";

import type { CommandPlan, CommandResult, CommandRunner } from "./types.js";

export class NodeCommandRunner implements CommandRunner {
  run(plan: CommandPlan): Promise<CommandResult> {
    const startedAt = Date.now();

    return new Promise((resolve) => {
      const child = spawn(plan.command, plan.args, {
        cwd: plan.cwd,
        env: {
          ...process.env,
          ...plan.env
        },
        stdio: ["ignore", "pipe", "pipe"]
      });

      let stdout = "";
      let stderr = "";
      let settled = false;
      let timedOut = false;
      const abort = () => {
        if (!settled) {
          child.kill("SIGTERM");
        }
      };

      const timeout = plan.timeoutMs === undefined
        ? undefined
        : setTimeout(() => {
            timedOut = true;
            child.kill("SIGTERM");
          }, plan.timeoutMs);

      if (plan.signal?.aborted) {
        abort();
      } else {
        plan.signal?.addEventListener("abort", abort, { once: true });
      }

      child.stdout.setEncoding("utf8");
      child.stderr.setEncoding("utf8");

      child.stdout.on("data", (chunk: string) => {
        stdout += chunk;
        plan.onOutput?.({ stream: "stdout", text: chunk });
      });

      child.stderr.on("data", (chunk: string) => {
        stderr += chunk;
        plan.onOutput?.({ stream: "stderr", text: chunk });
      });

      child.on("error", (error) => {
        if (settled) {
          return;
        }
        settled = true;
        plan.signal?.removeEventListener("abort", abort);
        if (timeout !== undefined) {
          clearTimeout(timeout);
        }
        resolve({
          exitCode: null,
          signal: null,
          stdout,
          stderr: stderr.length > 0 ? stderr : error.message,
          durationMs: Date.now() - startedAt,
          timedOut
        });
      });

      child.on("close", (exitCode, signal) => {
        if (settled) {
          return;
        }
        settled = true;
        plan.signal?.removeEventListener("abort", abort);
        if (timeout !== undefined) {
          clearTimeout(timeout);
        }
        resolve({
          exitCode: timedOut ? null : exitCode,
          signal,
          stdout,
          stderr,
          durationMs: Date.now() - startedAt,
          timedOut
        });
      });
    });
  }
}
