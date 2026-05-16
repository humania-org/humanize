export interface TokenStatsFields {
  inputTokens: number;
  outputTokens: number;
  cacheReadInputTokens: number;
  cacheCreationInputTokens: number;
  reasoningOutputTokens: number;
  totalTokens: number;
}

export type TokenStatsPatch = Partial<TokenStatsFields>;
export type TokenStatsBreakdown = Omit<TokenStatsFields, "totalTokens">;

export function emptyTokenStats(): TokenStatsFields {
  return {
    inputTokens: 0,
    outputTokens: 0,
    cacheReadInputTokens: 0,
    cacheCreationInputTokens: 0,
    reasoningOutputTokens: 0,
    totalTokens: 0
  };
}

export function addUsageObjectToStats(value: unknown, stats: TokenStatsFields): void {
  const usage = tokenStatsFromUsageObject(value);
  if (usage === undefined) {
    return;
  }

  stats.inputTokens += usage.inputTokens;
  stats.outputTokens += usage.outputTokens;
  stats.cacheReadInputTokens += usage.cacheReadInputTokens;
  stats.cacheCreationInputTokens += usage.cacheCreationInputTokens;
  stats.reasoningOutputTokens += usage.reasoningOutputTokens;
  recomputeTotalTokens(stats);
}

export function applyTokenStatsPatch(stats: TokenStatsFields, patch: TokenStatsPatch | undefined): void {
  if (patch === undefined) {
    return;
  }
  if (patch.inputTokens !== undefined) {
    stats.inputTokens = patch.inputTokens;
  }
  if (patch.outputTokens !== undefined) {
    stats.outputTokens = patch.outputTokens;
  }
  if (patch.cacheReadInputTokens !== undefined) {
    stats.cacheReadInputTokens = patch.cacheReadInputTokens;
  }
  if (patch.cacheCreationInputTokens !== undefined) {
    stats.cacheCreationInputTokens = patch.cacheCreationInputTokens;
  }
  if (patch.reasoningOutputTokens !== undefined) {
    stats.reasoningOutputTokens = patch.reasoningOutputTokens;
  }
  recomputeTotalTokens(stats);
}

export function recomputeTotalTokens(stats: TokenStatsFields): void {
  stats.totalTokens =
    stats.inputTokens +
    stats.outputTokens +
    stats.cacheReadInputTokens +
    stats.cacheCreationInputTokens +
    stats.reasoningOutputTokens;
}

export function tokenStatsFromUsageObject(value: unknown): TokenStatsBreakdown | undefined {
  const object = asRecord(value);
  if (object === undefined) {
    return undefined;
  }

  const rawInputTokens = firstNumber(object.input_tokens, object.inputTokens, object.prompt_tokens);
  const codexCachedInputTokens = firstNumber(object.cached_input_tokens, object.cachedInputTokens);
  const cacheReadInputTokens = firstNumber(
    object.cache_read_input_tokens,
    object.cacheReadInputTokens,
    codexCachedInputTokens
  ) ?? 0;
  const cacheCreationInputTokens = firstNumber(
    object.cache_creation_input_tokens,
    object.cacheCreationInputTokens
  ) ?? 0;
  const rawOutputTokens = firstNumber(object.output_tokens, object.outputTokens, object.completion_tokens);
  const reasoningOutputTokens = firstNumber(
    object.reasoning_output_tokens,
    object.reasoningOutputTokens
  ) ?? 0;

  if (
    rawInputTokens === undefined &&
    rawOutputTokens === undefined &&
    cacheReadInputTokens === 0 &&
    cacheCreationInputTokens === 0 &&
    reasoningOutputTokens === 0
  ) {
    return undefined;
  }

  return {
    inputTokens: rawInputTokens === undefined
      ? 0
      : Math.max(0, rawInputTokens - (codexCachedInputTokens ?? 0)),
    outputTokens: rawOutputTokens === undefined
      ? 0
      : Math.max(0, rawOutputTokens - reasoningOutputTokens),
    cacheReadInputTokens,
    cacheCreationInputTokens,
    reasoningOutputTokens
  };
}

export function contextInputTokensFromUsageObject(value: unknown): number | undefined {
  const object = asRecord(value);
  if (object === undefined) {
    return undefined;
  }

  const rawInputTokens = firstNumber(object.input_tokens, object.inputTokens, object.prompt_tokens);
  if (rawInputTokens === undefined) {
    return undefined;
  }

  if (firstNumber(object.cached_input_tokens, object.cachedInputTokens) !== undefined) {
    return rawInputTokens;
  }

  return rawInputTokens +
    (firstNumber(object.cache_read_input_tokens, object.cacheReadInputTokens) ?? 0) +
    (firstNumber(object.cache_creation_input_tokens, object.cacheCreationInputTokens) ?? 0);
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }

  return value as Record<string, unknown>;
}

function firstNumber(...values: unknown[]): number | undefined {
  return values.find((value): value is number => typeof value === "number" && Number.isFinite(value));
}
