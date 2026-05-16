import type {
  Edge,
  EdgeKind,
  GraphInstance,
  LoopMetadata,
  Vertex,
  VertexKind,
  WorkflowAgentNode,
  WorkflowAwaitNode,
  WorkflowBranchNode,
  WorkflowCartridge,
  WorkflowCheckNode,
  WorkflowHumanNode,
  WorkflowLoopNode,
  WorkflowMessageNode,
  WorkflowNode,
  WorkflowParallelNode,
  WorkflowScriptNode,
  WorkflowSequenceNode,
  WorkflowSleepNode,
  WorkflowTransformNode
} from "./types.js";

export class GraphCompileError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
    this.name = "GraphCompileError";
  }
}

interface ParallelScopeFrame {
  forkVertexId: string;
  joinVertexId: string;
  // Identifies which direct-child subtree of the fork the current vertex lives in.
  // Set when a child compilation begins; vertices created before the first child or
  // outside any child compilation share the synthetic `forkVertexId` slot.
  branchKey: string;
}

interface CompileContext {
  vertices: Map<string, Vertex>;
  edges: Map<string, Edge>;
  outgoing: Map<string, Edge[]>;
  incoming: Map<string, Edge[]>;
  loops: Map<string, LoopMetadata>;
  syntheticCounter: number;
  branchTargets: Array<{ branchId: string; targetId: string }>;
  continueTargets: Array<{ branchId: string; loopId: string }>;
  enclosingLoopStack: string[];
  enclosingLoopByVertex: Map<string, string | undefined>;
  parallelScopeStack: ParallelScopeFrame[];
  parallelScopesByVertex: Map<string, ParallelScopeFrame[]>;
  endMarkerVertexIds: string[];
  workflowEndVertexId?: string;
}

interface Segment {
  entryVertexId: string;
  exitVertexId: string;
}

const ANONYMOUS_ID_PREFIX = "__anon";

export function compileGraph(cartridge: WorkflowCartridge): GraphInstance {
  const ctx = createContext();

  const startId = makeSyntheticVertex(ctx, "start");
  const endId = makeSyntheticVertex(ctx, "end");
  ctx.workflowEndVertexId = endId;

  const flowSegment = compileChildSequence(ctx, cartridge.nodes);
  if (flowSegment === undefined) {
    addEdge(ctx, startId, endId, "fallthrough");
  } else {
    addEdge(ctx, startId, flowSegment.entryVertexId, "fallthrough");
    addEdge(ctx, flowSegment.exitVertexId, endId, "fallthrough");
  }

  for (const endMarkerId of ctx.endMarkerVertexIds) {
    addEdge(ctx, endMarkerId, endId, "fallthrough");
  }

  resolveBranchTargets(ctx);
  resolveContinueTargets(ctx);
  validateBranchScoping(ctx);
  validateCycles(ctx, startId);

  return {
    vertices: ctx.vertices,
    edges: ctx.edges,
    outgoing: ctx.outgoing,
    incoming: ctx.incoming,
    startVertexId: startId,
    endVertexId: endId,
    loops: ctx.loops
  };
}

function createContext(): CompileContext {
  return {
    vertices: new Map(),
    edges: new Map(),
    outgoing: new Map(),
    incoming: new Map(),
    loops: new Map(),
    syntheticCounter: 0,
    branchTargets: [],
    continueTargets: [],
    enclosingLoopStack: [],
    enclosingLoopByVertex: new Map(),
    parallelScopeStack: [],
    parallelScopesByVertex: new Map(),
    endMarkerVertexIds: []
  };
}

function compileChildSequence(ctx: CompileContext, children: WorkflowNode[]): Segment | undefined {
  if (children.length === 0) {
    return undefined;
  }
  const segments = children.map((child, index) => ({
    segment: compileNode(ctx, child),
    suppressFallthrough: child.type === "end"
  }));
  for (let index = 0; index < segments.length - 1; index += 1) {
    if (segments[index].suppressFallthrough) {
      continue;
    }
    addEdge(ctx, segments[index].segment.exitVertexId, segments[index + 1].segment.entryVertexId, "fallthrough");
  }
  return {
    entryVertexId: segments[0].segment.entryVertexId,
    exitVertexId: segments[segments.length - 1].segment.exitVertexId
  };
}

function compileNode(ctx: CompileContext, node: WorkflowNode): Segment {
  switch (node.type) {
    case "sequence":
      return compileSequenceNode(ctx, node);
    case "parallel":
      return compileParallelNode(ctx, node);
    case "loop":
      return compileLoopNode(ctx, node);
    case "branch":
      return compileBranchNode(ctx, node);
    case "end":
      return compileEndNode(ctx, node);
    case "agent":
    case "message":
    case "human":
    case "await":
    case "script":
    case "check":
    case "transform":
    case "sleep":
      return compileAtomicNode(ctx, node);
  }
}

function compileEndNode(ctx: CompileContext, node: { type: "end"; id?: string }): Segment {
  const vertexId = makeNamedVertex(ctx, node.id, "end-marker");
  ctx.endMarkerVertexIds.push(vertexId);
  return { entryVertexId: vertexId, exitVertexId: vertexId };
}

function compileSequenceNode(ctx: CompileContext, node: WorkflowSequenceNode): Segment {
  const inner = compileChildSequence(ctx, node.children);
  if (inner !== undefined) {
    return inner;
  }
  const vertexId = makeSyntheticVertex(ctx, "sequence", node);
  return { entryVertexId: vertexId, exitVertexId: vertexId };
}

function compileParallelNode(ctx: CompileContext, node: WorkflowParallelNode): Segment {
  const forkId = makeNamedVertex(ctx, node.id, "parallel-fork", node);
  const joinId = makeSyntheticVertex(ctx, "parallel-join", node);

  if (node.children.length === 0) {
    addEdge(ctx, forkId, joinId, "fallthrough");
    return { entryVertexId: forkId, exitVertexId: joinId };
  }

  let branchOrdinal = 0;
  for (const child of node.children) {
    branchOrdinal += 1;
    const frame: ParallelScopeFrame = {
      forkVertexId: forkId,
      joinVertexId: joinId,
      branchKey: `${forkId}#branch-${branchOrdinal}`
    };
    ctx.parallelScopeStack.push(frame);
    let childSegment: Segment;
    try {
      childSegment = compileNode(ctx, child);
    } finally {
      ctx.parallelScopeStack.pop();
    }
    addEdge(ctx, forkId, childSegment.entryVertexId, "fork");
    addEdge(ctx, childSegment.exitVertexId, joinId, "join");
  }
  return { entryVertexId: forkId, exitVertexId: joinId };
}

function compileLoopNode(ctx: CompileContext, node: WorkflowLoopNode): Segment {
  if (node.id.length === 0) {
    throw new GraphCompileError("cartridge.loop_missing_id", "h2-loop requires id");
  }

  const parentLoopId = currentEnclosingLoopId(ctx);
  ctx.enclosingLoopStack.push(node.id);
  const startVertexIndex = ctx.vertices.size;
  const entryId = makeNamedVertex(ctx, node.id, "loop-entry", node);
  const tailId = makeSyntheticVertex(ctx, "loop-tail", node);

  ctx.loops.set(node.id, {
    loopVertexId: entryId,
    entryVertexId: entryId,
    tailVertexId: tailId,
    parentLoopId,
    bodyVertexIds: [],
    max: node.max,
    whileExpr: node.while
  });

  const bodySegment = compileChildSequence(ctx, node.children);
  ctx.enclosingLoopStack.pop();

  if (bodySegment === undefined) {
    addEdge(ctx, entryId, tailId, "fallthrough");
  } else {
    addEdge(ctx, entryId, bodySegment.entryVertexId, "fallthrough");
    addEdge(ctx, bodySegment.exitVertexId, tailId, "fallthrough");
  }

  addEdge(ctx, tailId, entryId, "backedge", undefined, node.id);

  const meta = ctx.loops.get(node.id)!;
  const bodyIds: string[] = [];
  let index = 0;
  for (const vertexId of ctx.vertices.keys()) {
    if (index >= startVertexIndex) {
      bodyIds.push(vertexId);
    }
    index += 1;
  }
  meta.bodyVertexIds = bodyIds;

  return { entryVertexId: entryId, exitVertexId: tailId };
}

function compileBranchNode(ctx: CompileContext, node: WorkflowBranchNode): Segment {
  const branchId = makeNamedVertex(ctx, node.id, "branch", node);

  for (const branchCase of node.cases) {
    if (branchCase.goto !== undefined) {
      ctx.branchTargets.push({ branchId, targetId: branchCase.goto });
      registerBranchEdge(ctx, branchId, branchCase.goto, "branch", branchCase.value);
    } else if (branchCase.continueLoop !== undefined) {
      ctx.continueTargets.push({ branchId, loopId: branchCase.continueLoop });
      registerBranchEdge(ctx, branchId, branchCase.continueLoop, "continue-edge", branchCase.value, branchCase.continueLoop);
    }
  }

  ctx.branchTargets.push({ branchId, targetId: node.defaultTarget });
  registerBranchEdge(ctx, branchId, node.defaultTarget, "branch-default", undefined);

  return { entryVertexId: branchId, exitVertexId: branchId };
}

function compileAtomicNode(
  ctx: CompileContext,
  node:
    | WorkflowAgentNode
    | WorkflowMessageNode
    | WorkflowHumanNode
    | WorkflowAwaitNode
    | WorkflowScriptNode
    | WorkflowCheckNode
    | WorkflowTransformNode
    | WorkflowSleepNode
): Segment {
  const kind = atomicVertexKind(node.type);
  const vertexId = makeNamedVertex(ctx, node.id, kind, node);
  return { entryVertexId: vertexId, exitVertexId: vertexId };
}

function atomicVertexKind(nodeType: WorkflowNode["type"]): VertexKind {
  switch (nodeType) {
    case "agent":
      return "agent";
    case "message":
      return "message";
    case "human":
      return "human";
    case "await":
      return "await";
    case "script":
      return "script";
    case "check":
      return "check";
    case "transform":
      return "transform";
    case "sleep":
      return "sleep";
    default:
      throw new GraphCompileError("cartridge.unsupported_node", `cannot make atomic vertex for ${nodeType}`);
  }
}

function makeNamedVertex(
  ctx: CompileContext,
  id: string | undefined,
  kind: VertexKind,
  node?: WorkflowNode
): string {
  const vertexId = id !== undefined && id.length > 0 ? id : makeSyntheticVertexId(ctx, kind);
  if (ctx.vertices.has(vertexId)) {
    throw new GraphCompileError("cartridge.duplicate_id", `duplicate vertex id: ${vertexId}`);
  }
  const enclosingLoopId = currentEnclosingLoopId(ctx);
  ctx.vertices.set(vertexId, { id: vertexId, kind, node, enclosingLoopId });
  ctx.enclosingLoopByVertex.set(vertexId, enclosingLoopId);
  recordParallelScopes(ctx, vertexId);
  return vertexId;
}

function makeSyntheticVertex(ctx: CompileContext, kind: VertexKind, node?: WorkflowNode): string {
  const vertexId = makeSyntheticVertexId(ctx, kind);
  const enclosingLoopId = currentEnclosingLoopId(ctx);
  ctx.vertices.set(vertexId, { id: vertexId, kind, node, enclosingLoopId });
  ctx.enclosingLoopByVertex.set(vertexId, enclosingLoopId);
  recordParallelScopes(ctx, vertexId);
  return vertexId;
}

function recordParallelScopes(ctx: CompileContext, vertexId: string): void {
  if (ctx.parallelScopeStack.length === 0) {
    return;
  }
  ctx.parallelScopesByVertex.set(vertexId, [...ctx.parallelScopeStack]);
}

function makeSyntheticVertexId(ctx: CompileContext, kind: VertexKind): string {
  ctx.syntheticCounter += 1;
  return `${ANONYMOUS_ID_PREFIX}-${kind}-${ctx.syntheticCounter}`;
}

function currentEnclosingLoopId(ctx: CompileContext): string | undefined {
  const stack = ctx.enclosingLoopStack;
  return stack.length === 0 ? undefined : stack[stack.length - 1];
}

function addEdge(
  ctx: CompileContext,
  from: string,
  to: string,
  kind: EdgeKind,
  matchValue?: string,
  loopId?: string
): Edge {
  const edgeId = `edge-${ctx.edges.size + 1}`;
  const edge: Edge = { id: edgeId, from, to, kind, matchValue, loopId };
  ctx.edges.set(edgeId, edge);
  appendList(ctx.outgoing, from, edge);
  appendList(ctx.incoming, to, edge);
  return edge;
}

function registerBranchEdge(
  ctx: CompileContext,
  from: string,
  to: string,
  kind: EdgeKind,
  matchValue: string | undefined,
  loopId?: string
): Edge {
  return addEdge(ctx, from, to, kind, matchValue, loopId);
}

function appendList<K, V>(map: Map<K, V[]>, key: K, value: V): void {
  const list = map.get(key);
  if (list === undefined) {
    map.set(key, [value]);
  } else {
    list.push(value);
  }
}

function resolveBranchTargets(ctx: CompileContext): void {
  for (const { branchId, targetId } of ctx.branchTargets) {
    if (!ctx.vertices.has(targetId)) {
      throw new GraphCompileError(
        "cartridge.invalid_goto_target",
        `branch ${branchId} references unknown vertex: ${targetId}`
      );
    }
  }
}

function resolveContinueTargets(ctx: CompileContext): void {
  for (const { branchId, loopId } of ctx.continueTargets) {
    if (!ctx.loops.has(loopId)) {
      throw new GraphCompileError(
        "cartridge.continue_unknown_loop",
        `branch ${branchId} uses continue=${loopId} but no loop with that id exists`
      );
    }
    const branchVertex = ctx.vertices.get(branchId);
    if (branchVertex === undefined || !isInEnclosingLoopChain(ctx, branchVertex.enclosingLoopId, loopId)) {
      throw new GraphCompileError(
        "cartridge.continue_not_enclosing",
        `branch ${branchId} uses continue=${loopId} but ${loopId} is not in the branch's enclosing loop chain`
      );
    }
  }
}

function isInEnclosingLoopChain(ctx: CompileContext, startLoopId: string | undefined, targetLoopId: string): boolean {
  let current = startLoopId;
  while (current !== undefined) {
    if (current === targetLoopId) {
      return true;
    }
    current = ctx.loops.get(current)?.parentLoopId;
  }
  return false;
}

function validateBranchScoping(ctx: CompileContext): void {
  for (const edge of ctx.edges.values()) {
    if (edge.kind !== "branch" && edge.kind !== "branch-default" && edge.kind !== "continue-edge") {
      continue;
    }
    const target = ctx.vertices.get(edge.to);
    if (target === undefined) {
      continue;
    }
    const source = ctx.vertices.get(edge.from);
    if (source === undefined) {
      continue;
    }

    // Loop-body escape check: a branch / branch-default may not target a vertex
    // inside a loop body that the source vertex does not enclose. `continue-edge`
    // edges are exempted from this rule because they encode the explicit
    // back-edge semantics validated elsewhere.
    if (edge.kind !== "continue-edge") {
      const targetLoopId = target.enclosingLoopId;
      if (targetLoopId !== undefined && !isInEnclosingLoopChain(ctx, source.enclosingLoopId, targetLoopId)) {
        throw new GraphCompileError(
          "cartridge.goto_into_loop_body",
          `branch ${edge.from} routes via ${edge.kind} into ${edge.to} which belongs to loop ${targetLoopId}; goto from outside a loop into the loop body is not allowed (use continue=${targetLoopId} for back-edge semantics)`
        );
      }
    }

    // Parallel-scope escape check: when the source vertex is inside one or more
    // parallel branches, the target must either live in the same parallel branch
    // subtree (transitively under the same fork) or equal the parallel-join
    // vertex for that fork. `continue-edge` targeting an outer loop is allowed
    // by the spec but only when that loop transitively encloses the parallel
    // scope; the loop-chain check above already enforces that constraint for
    // non-continue edges, and continue-edge resolution rejects loops that are
    // not in the branch's enclosing loop chain.
    const sourceScopes = ctx.parallelScopesByVertex.get(edge.from) ?? [];
    if (sourceScopes.length === 0) {
      continue;
    }
    const targetScopes = ctx.parallelScopesByVertex.get(edge.to) ?? [];
    for (const sourceFrame of sourceScopes) {
      // Continue-edge: only valid if the target loop encloses the parallel scope.
      // We approximate this by allowing the edge when the loop the continue
      // targets is an enclosing loop of the parallel fork itself; that holds
      // when the fork vertex shares the targeted loop in its enclosing loop
      // chain. resolveContinueTargets already verified that the branch sits
      // inside the targeted loop chain.
      if (edge.kind === "continue-edge") {
        const forkVertex = ctx.vertices.get(sourceFrame.forkVertexId);
        if (
          forkVertex !== undefined &&
          edge.loopId !== undefined &&
          isInEnclosingLoopChain(ctx, forkVertex.enclosingLoopId, edge.loopId)
        ) {
          continue;
        }
      }

      // Allow targeting the parallel-join vertex for the same fork.
      if (edge.to === sourceFrame.joinVertexId) {
        continue;
      }

      const targetFrame = targetScopes.find((frame) => frame.forkVertexId === sourceFrame.forkVertexId);
      if (targetFrame === undefined || targetFrame.branchKey !== sourceFrame.branchKey) {
        throw new GraphCompileError(
          "cartridge.parallel_branch_escape",
          `parallel_branch_escape: branch ${edge.from} routes via ${edge.kind} into ${edge.to} which escapes the parallel branch under fork ${sourceFrame.forkVertexId}; parallel branches may only target siblings within the same branch or the parallel-join vertex`
        );
      }
    }
  }
}

function validateCycles(ctx: CompileContext, startId: string): void {
  const reachable = computeReachable(ctx, startId);
  const filteredOutgoing = new Map<string, Edge[]>();
  for (const [vertexId, edges] of ctx.outgoing.entries()) {
    if (!reachable.has(vertexId)) {
      continue;
    }
    filteredOutgoing.set(vertexId, edges.filter((edge) => edge.kind !== "backedge" && edge.kind !== "continue-edge" && reachable.has(edge.to)));
  }
  const components = tarjanSCC(ctx, startId, filteredOutgoing);
  for (const component of components) {
    if (component.length === 1) {
      const selfLoop = (filteredOutgoing.get(component[0]) ?? []).some((edge) => edge.to === component[0]);
      if (!selfLoop) {
        continue;
      }
    }
    throw new GraphCompileError(
      "cartridge.invalid_cycle",
      `cartridge has a cycle that is not closed by a loop back-edge or continue-edge: ${component.join(", ")}`
    );
  }
}

function computeReachable(ctx: CompileContext, startId: string): Set<string> {
  const reachable = new Set<string>();
  const stack: string[] = [startId];
  while (stack.length > 0) {
    const vertexId = stack.pop()!;
    if (reachable.has(vertexId)) {
      continue;
    }
    reachable.add(vertexId);
    const edges = ctx.outgoing.get(vertexId) ?? [];
    for (const edge of edges) {
      stack.push(edge.to);
    }
  }
  return reachable;
}

function tarjanSCC(
  ctx: CompileContext,
  startId: string,
  outgoingOverride?: Map<string, Edge[]>
): string[][] {
  const outgoing = outgoingOverride ?? ctx.outgoing;
  let index = 0;
  const stack: string[] = [];
  const onStack = new Set<string>();
  const indices = new Map<string, number>();
  const lowlinks = new Map<string, number>();
  const result: string[][] = [];

  function strongConnect(vertexId: string): void {
    indices.set(vertexId, index);
    lowlinks.set(vertexId, index);
    index += 1;
    stack.push(vertexId);
    onStack.add(vertexId);

    const outgoingEdges = outgoing.get(vertexId) ?? [];
    for (const edge of outgoingEdges) {
      const target = edge.to;
      if (!indices.has(target)) {
        strongConnect(target);
        lowlinks.set(vertexId, Math.min(lowlinks.get(vertexId)!, lowlinks.get(target)!));
      } else if (onStack.has(target)) {
        lowlinks.set(vertexId, Math.min(lowlinks.get(vertexId)!, indices.get(target)!));
      }
    }

    if (lowlinks.get(vertexId) === indices.get(vertexId)) {
      const component: string[] = [];
      let popped: string;
      do {
        popped = stack.pop()!;
        onStack.delete(popped);
        component.push(popped);
      } while (popped !== vertexId);
      if (component.length > 1 || (outgoing.get(vertexId) ?? []).some((edge) => edge.to === vertexId)) {
        result.push(component);
      }
    }
  }

  strongConnect(startId);
  for (const vertexId of ctx.vertices.keys()) {
    if (!indices.has(vertexId)) {
      strongConnect(vertexId);
    }
  }
  return result;
}
