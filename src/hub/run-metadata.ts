import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve } from "node:path";

export interface RunProjectMetadata {
  path?: string;
  git: {
    isRepo: boolean;
    root?: string;
    remoteUrl?: string;
    branch?: string;
    isLinkedWorktree?: boolean;
    mainWorktreePath?: string;
  };
}

export function deriveShortName(prompt: string): string {
  const firstLine = prompt.split(/\r?\n/).find((line) => line.trim().length > 0)?.trim() ?? "agent run";
  const compact = firstLine.replace(/\s+/g, " ");
  return compact.length > 80 ? `${compact.slice(0, 77)}...` : compact;
}

export function collectProjectMetadata(cwd: string | undefined): RunProjectMetadata {
  if (cwd === undefined || cwd.length === 0) {
    return {
      git: {
        isRepo: false
      }
    };
  }

  if (!existsSync(cwd)) {
    return {
      path: cwd,
      git: {
        isRepo: false
      }
    };
  }

  const isRepo = runGit(cwd, ["rev-parse", "--is-inside-work-tree"]) === "true";
  if (!isRepo) {
    return {
      path: cwd,
      git: {
        isRepo: false
      }
    };
  }

  const gitDir = runGit(cwd, ["rev-parse", "--absolute-git-dir"]);
  const commonDir = runGit(cwd, ["rev-parse", "--git-common-dir"]);
  const linkedWorktree = detectLinkedWorktree(gitDir, commonDir);

  return {
    path: cwd,
    git: {
      isRepo: true,
      root: runGit(cwd, ["rev-parse", "--show-toplevel"]),
      remoteUrl: runGit(cwd, ["remote", "get-url", "origin"]) || undefined,
      branch: runGit(cwd, ["branch", "--show-current"]) || undefined,
      isLinkedWorktree: linkedWorktree,
      mainWorktreePath: linkedWorktree ? firstWorktreePath(cwd) : undefined
    }
  };
}

function detectLinkedWorktree(gitDir: string, commonDir: string): boolean {
  if (gitDir.length === 0 || commonDir.length === 0) {
    return false;
  }

  const resolvedGitDir = resolve(gitDir);
  const resolvedCommonDir = resolve(commonDir);
  return resolvedGitDir !== resolvedCommonDir && resolvedGitDir.includes("/worktrees/");
}

function firstWorktreePath(cwd: string): string | undefined {
  const output = runGit(cwd, ["worktree", "list", "--porcelain"]);
  const firstLine = output.split("\n").find((line) => line.startsWith("worktree "));
  return firstLine?.slice("worktree ".length);
}

function runGit(cwd: string, args: string[]): string {
  try {
    return execFileSync("git", args, {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 2_000
    }).trim();
  } catch {
    return "";
  }
}
