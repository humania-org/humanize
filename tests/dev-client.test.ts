import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { describe, expect, it } from "vitest";

import { parseToolArguments } from "../src/dev-client.js";

describe("dev-client argument parsing", () => {
  it("parses inline JSON arguments", async () => {
    await expect(parseToolArguments('{"agent":"codex","prompt":"hello"}')).resolves.toEqual({
      agent: "codex",
      prompt: "hello"
    });
  });

  it("parses JSON arguments from an @file reference", async () => {
    const directory = await mkdtemp(join(tmpdir(), "humanize2-dev-client-"));
    const filePath = join(directory, "arguments.json");

    try {
      await writeFile(filePath, JSON.stringify({ prompt: "nested", timeoutMs: 1000 }), "utf8");

      await expect(parseToolArguments(`@${filePath}`)).resolves.toEqual({
        prompt: "nested",
        timeoutMs: 1000
      });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });
});
