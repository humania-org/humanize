import type { ArtifactRecord, GraphInstance, WorkflowRunRecord } from "./types.js";

export interface PredicateContext {
  graph: GraphInstance;
  loopIterations: Map<string, number>;
  currentLoopId?: string;
  // Set of event types observed since the await currently being evaluated entered the
  // inflight state. Resolving `event.<type>` returns true if and only if `<type>` is in
  // this set. Undefined means the predicate is not being evaluated for an h2-await vertex.
  awaitObservedEventTypes?: Set<string>;
}

export interface ArtifactReferenceContext {
  warnings: WorkflowExpressionWarning[];
}

export interface WorkflowExpressionWarning {
  kind: "artifact.ambiguous_reference";
  artifactName: string;
}

export function evaluatePredicate(
  context: PredicateContext | undefined,
  run: WorkflowRunRecord,
  expression: string,
  warnings?: WorkflowExpressionWarning[]
): boolean {
  const trimmed = expression.trim();
  if (trimmed.length === 0) {
    return false;
  }
  const tokens = tokenize(trimmed);
  return evalExpr(tokens, context, run, warnings);
}

export function resolvePath(
  context: PredicateContext | undefined,
  run: WorkflowRunRecord,
  path: string,
  warnings?: WorkflowExpressionWarning[]
): unknown {
  const tokens = tokenize(path.trim());
  const cursor: TokenCursor = { tokens, pos: 0 };
  const segments = parsePath(cursor);
  if (cursor.pos !== tokens.length) {
    throw new Error(`Trailing tokens in path: ${path}`);
  }
  return resolveSegments(segments, context, run, warnings);
}

type Token =
  | { kind: "ident"; value: string }
  | { kind: "bracket"; value: string }
  | { kind: "string"; value: string }
  | { kind: "number"; value: number }
  | { kind: "lparen" }
  | { kind: "rparen" }
  | { kind: "dot" }
  | { kind: "at" }
  | { kind: "eq" }
  | { kind: "neq" }
  | { kind: "not" }
  | { kind: "exists" }
  | { kind: "true" }
  | { kind: "false" }
  | { kind: "null" };

interface PathSegment {
  text: string;
  qualifier?: string;
}

function tokenize(input: string): Token[] {
  const tokens: Token[] = [];
  let i = 0;
  while (i < input.length) {
    const ch = input[i];
    if (ch === " " || ch === "\t" || ch === "\n") {
      i += 1;
      continue;
    }
    if (ch === "(") {
      tokens.push({ kind: "lparen" });
      i += 1;
      continue;
    }
    if (ch === ")") {
      tokens.push({ kind: "rparen" });
      i += 1;
      continue;
    }
    if (ch === ".") {
      tokens.push({ kind: "dot" });
      i += 1;
      continue;
    }
    if (ch === "@") {
      tokens.push({ kind: "at" });
      i += 1;
      continue;
    }
    if (ch === "=" && input[i + 1] === "=") {
      tokens.push({ kind: "eq" });
      i += 2;
      continue;
    }
    if (ch === "!" && input[i + 1] === "=") {
      tokens.push({ kind: "neq" });
      i += 2;
      continue;
    }
    if (ch === "'") {
      const end = input.indexOf("'", i + 1);
      if (end === -1) {
        throw new Error(`Unterminated string literal in expression: ${input}`);
      }
      tokens.push({ kind: "string", value: input.slice(i + 1, end) });
      i = end + 1;
      continue;
    }
    if (ch === "[") {
      const end = input.indexOf("]", i + 1);
      if (end === -1) {
        throw new Error(`Unterminated bracket segment in expression: ${input}`);
      }
      tokens.push({ kind: "bracket", value: input.slice(i + 1, end) });
      i = end + 1;
      continue;
    }
    if (/[0-9]/.test(ch)) {
      let j = i + 1;
      while (j < input.length && /[0-9_.\-]/.test(input[j])) {
        j += 1;
      }
      const raw = input.slice(i, j);
      const numeric = Number.parseFloat(raw);
      tokens.push({ kind: "number", value: numeric });
      i = j;
      continue;
    }
    if (/[A-Za-z_]/.test(ch)) {
      let j = i + 1;
      while (j < input.length && /[A-Za-z0-9_-]/.test(input[j])) {
        j += 1;
      }
      const word = input.slice(i, j);
      switch (word) {
        case "not":
          tokens.push({ kind: "not" });
          break;
        case "exists":
          tokens.push({ kind: "exists" });
          break;
        case "true":
          tokens.push({ kind: "true" });
          break;
        case "false":
          tokens.push({ kind: "false" });
          break;
        case "null":
          tokens.push({ kind: "null" });
          break;
        default:
          tokens.push({ kind: "ident", value: word });
      }
      i = j;
      continue;
    }
    throw new Error(`Unexpected character '${ch}' in expression: ${input}`);
  }
  return tokens;
}

interface TokenCursor {
  tokens: Token[];
  pos: number;
}

function evalExpr(
  tokens: Token[],
  context: PredicateContext | undefined,
  run: WorkflowRunRecord,
  warnings?: WorkflowExpressionWarning[]
): boolean {
  const cursor: TokenCursor = { tokens, pos: 0 };
  const value = parseExpr(cursor, context, run, warnings);
  if (cursor.pos !== cursor.tokens.length) {
    throw new Error("Trailing tokens in expression");
  }
  return toBoolean(value);
}

function parseExpr(
  cursor: TokenCursor,
  context: PredicateContext | undefined,
  run: WorkflowRunRecord,
  warnings: WorkflowExpressionWarning[] | undefined
): unknown {
  const next = cursor.tokens[cursor.pos];
  if (next === undefined) {
    return undefined;
  }
  if (next.kind === "not") {
    cursor.pos += 1;
    const sub = parseExpr(cursor, context, run, warnings);
    return !toBoolean(sub);
  }
  if (next.kind === "exists") {
    cursor.pos += 1;
    expect(cursor, "lparen");
    const path = parsePath(cursor);
    expect(cursor, "rparen");
    const value = resolveSegments(path, context, run, warnings);
    return value !== undefined && value !== null;
  }

  const leftPath = parsePath(cursor);
  const leftValue = resolveSegments(leftPath, context, run, warnings);
  const opToken = cursor.tokens[cursor.pos];
  if (opToken === undefined) {
    return leftValue;
  }
  if (opToken.kind === "eq") {
    cursor.pos += 1;
    const right = parseLiteral(cursor);
    return strictlyEqual(leftValue, right);
  }
  if (opToken.kind === "neq") {
    cursor.pos += 1;
    const right = parseLiteral(cursor);
    return !strictlyEqual(leftValue, right);
  }
  return leftValue;
}

function parsePath(cursor: TokenCursor): PathSegment[] {
  const segments: PathSegment[] = [];
  while (cursor.pos < cursor.tokens.length) {
    const token = cursor.tokens[cursor.pos];
    let text: string | undefined;
    if (token.kind === "ident") {
      text = token.value;
    } else if (token.kind === "bracket") {
      text = token.value;
    } else if (token.kind === "true") {
      text = "true";
    } else if (token.kind === "false") {
      text = "false";
    } else if (token.kind === "null") {
      text = "null";
    }
    if (text === undefined) {
      break;
    }
    cursor.pos += 1;
    let qualifier: string | undefined;
    if (cursor.tokens[cursor.pos]?.kind === "at") {
      cursor.pos += 1;
      const qToken = cursor.tokens[cursor.pos];
      if (qToken === undefined || (qToken.kind !== "ident" && qToken.kind !== "bracket")) {
        throw new Error("Expected qualifier after '@'");
      }
      qualifier = qToken.kind === "ident" ? qToken.value : qToken.value;
      cursor.pos += 1;
    }
    segments.push({ text, qualifier });
    const nextToken = cursor.tokens[cursor.pos];
    if (nextToken?.kind === "dot") {
      cursor.pos += 1;
    } else {
      break;
    }
  }
  if (segments.length === 0) {
    throw new Error("Expected path in expression");
  }
  return segments;
}

function parseLiteral(cursor: TokenCursor): unknown {
  const token = cursor.tokens[cursor.pos];
  if (token === undefined) {
    throw new Error("Expected literal after comparison operator");
  }
  cursor.pos += 1;
  switch (token.kind) {
    case "string":
      return token.value;
    case "number":
      return token.value;
    case "true":
      return true;
    case "false":
      return false;
    case "null":
      return null;
    case "ident":
      return token.value;
    default:
      throw new Error(`Unexpected token after operator: ${token.kind}`);
  }
}

function expect(cursor: TokenCursor, kind: Token["kind"]): void {
  const token = cursor.tokens[cursor.pos];
  if (token === undefined || token.kind !== kind) {
    throw new Error(`Expected ${kind} in expression`);
  }
  cursor.pos += 1;
}

function resolveSegments(
  segments: PathSegment[],
  context: PredicateContext | undefined,
  run: WorkflowRunRecord,
  warnings?: WorkflowExpressionWarning[]
): unknown {
  if (segments.length === 0) {
    return undefined;
  }
  const root = segments[0];
  switch (root.text) {
    case "artifact":
      return resolveArtifactPath(segments.slice(1), context, run, warnings);
    case "board":
      return resolveBoardPath(segments.slice(1), run);
    case "var":
      return resolveVarPath(segments.slice(1), run);
    case "loop":
      return resolveLoopPath(segments.slice(1), context);
    case "event":
      return resolveEventPath(segments.slice(1), context);
    default:
      return undefined;
  }
}

function resolveEventPath(segments: PathSegment[], context: PredicateContext | undefined): unknown {
  if (segments.length === 0 || context?.awaitObservedEventTypes === undefined) {
    return false;
  }
  const eventType = segments[0].text;
  return context.awaitObservedEventTypes.has(eventType);
}

function resolveArtifactPath(
  segments: PathSegment[],
  context: PredicateContext | undefined,
  run: WorkflowRunRecord,
  warnings?: WorkflowExpressionWarning[]
): unknown {
  if (segments.length === 0) {
    return undefined;
  }
  const head = segments[0];
  const name = head.text;
  const qualifier = head.qualifier;
  const candidates = run.artifacts.filter((artifact) => artifact.name === name);
  if (candidates.length === 0) {
    return undefined;
  }
  const selected = selectArtifactByQualifier(candidates, qualifier, context, name, warnings);
  if (selected === undefined) {
    return undefined;
  }
  if (selected.validationStatus === "schema-mismatch") {
    if (segments.length === 1) {
      return undefined;
    }
    return undefined;
  }
  if (segments.length === 1) {
    return selected.content;
  }
  return drillIntoField(selected.content, segments.slice(1));
}

function selectArtifactByQualifier(
  candidates: ArtifactRecord[],
  qualifier: string | undefined,
  context: PredicateContext | undefined,
  name: string,
  warnings?: WorkflowExpressionWarning[]
): ArtifactRecord | undefined {
  if (qualifier === undefined) {
    if (context?.currentLoopId !== undefined) {
      const currentIteration = context.loopIterations.get(context.currentLoopId);
      if (currentIteration !== undefined) {
        const match = selectLatestUsable(candidates.filter((artifact) => (artifact.iteration ?? 1) === currentIteration));
        if (match !== undefined) {
          return match;
        }
        return undefined;
      }
    }
    if (candidates.length > 1) {
      warnings?.push({ kind: "artifact.ambiguous_reference", artifactName: name });
    }
    return selectLatestUsable(candidates);
  }
  if (qualifier === "latest") {
    return selectLatestUsable(candidates);
  }
  if (qualifier === "current") {
    if (context?.currentLoopId !== undefined) {
      const currentIteration = context.loopIterations.get(context.currentLoopId);
      if (currentIteration !== undefined) {
        return selectLatestUsable(candidates.filter((artifact) => (artifact.iteration ?? 1) === currentIteration));
      }
    }
    return selectLatestUsable(candidates);
  }
  if (qualifier.startsWith("iter-")) {
    const iteration = Number.parseInt(qualifier.slice("iter-".length), 10);
    if (!Number.isFinite(iteration)) {
      return undefined;
    }
    return selectLatestUsable(candidates.filter((artifact) => (artifact.iteration ?? 1) === iteration));
  }
  return undefined;
}

function selectLatestUsable(candidates: ArtifactRecord[]): ArtifactRecord | undefined {
  for (let index = candidates.length - 1; index >= 0; index -= 1) {
    const candidate = candidates[index];
    if (candidate.validationStatus !== "schema-mismatch") {
      return candidate;
    }
  }
  return candidates[candidates.length - 1];
}

function resolveBoardPath(segments: PathSegment[], run: WorkflowRunRecord): unknown {
  if (segments.length === 0) {
    return undefined;
  }
  const board = run.boards.find((item) => item.id === segments[0].text);
  if (board === undefined) {
    return undefined;
  }
  if (segments.length === 1) {
    return board.value;
  }
  return drillIntoField(board.value, segments.slice(1));
}

function resolveVarPath(segments: PathSegment[], run: WorkflowRunRecord): unknown {
  if (segments.length === 0) {
    return undefined;
  }
  return run.vars[segments[0].text];
}

function resolveLoopPath(segments: PathSegment[], context: PredicateContext | undefined): unknown {
  if (context === undefined || segments.length < 2 || segments[1].text !== "iteration") {
    return undefined;
  }
  const loopId = segments[0].text;
  const meta = context.graph.loops.get(loopId);
  if (meta === undefined) {
    return undefined;
  }
  return context.loopIterations.get(meta.entryVertexId);
}

function drillIntoField(content: unknown, segments: PathSegment[]): unknown {
  let current: unknown = content;
  for (const segment of segments) {
    if (current === undefined || current === null || typeof current !== "object") {
      return undefined;
    }
    current = (current as Record<string, unknown>)[segment.text];
  }
  return current;
}

function toBoolean(value: unknown): boolean {
  if (value === undefined || value === null) {
    return false;
  }
  if (typeof value === "boolean") {
    return value;
  }
  if (typeof value === "number") {
    return value !== 0;
  }
  if (typeof value === "string") {
    return value.length > 0;
  }
  return true;
}

function strictlyEqual(left: unknown, right: unknown): boolean {
  if (typeof left !== typeof right) {
    if (typeof left === "string" && typeof right === "number") {
      return Number.parseFloat(left) === right;
    }
    if (typeof right === "string" && typeof left === "number") {
      return Number.parseFloat(right) === left;
    }
    return false;
  }
  return left === right;
}
