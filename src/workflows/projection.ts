import type {
  GraphInstance,
  WorkflowAgentNode,
  WorkflowAwaitNode,
  WorkflowBranchNode,
  WorkflowCartridge,
  WorkflowCheckNode,
  WorkflowDashboardProjection,
  WorkflowEndNode,
  WorkflowFlowProjectionNode,
  WorkflowHumanNode,
  WorkflowLoopNode,
  WorkflowMessageNode,
  WorkflowNode,
  WorkflowScriptNode,
  WorkflowSleepNode,
  WorkflowTransformNode,
  WorkflowRunRecord
} from "./types.js";

type RuntimeStatus = WorkflowFlowProjectionNode["status"];

export function buildWorkflowProjection(
  cartridge: WorkflowCartridge,
  graph: GraphInstance,
  run: WorkflowRunRecord
): WorkflowDashboardProjection {
  void graph;
  return {
    flow: {
      nodes: projectChildren(cartridge.nodes, run)
    }
  };
}

function projectChildren(nodes: WorkflowNode[], run: WorkflowRunRecord): WorkflowFlowProjectionNode[] {
  return nodes.flatMap((node) => {
    if (node.type === "sequence") {
      return projectChildren(node.children, run);
    }
    return [projectNode(node, run)];
  });
}

function projectNode(node: WorkflowNode, run: WorkflowRunRecord): WorkflowFlowProjectionNode {
  switch (node.type) {
    case "parallel":
      return {
        id: node.id ?? "parallel",
        kind: "parallel",
        label: node.id ?? "parallel",
        status: statusForNode(run, node.id),
        children: projectChildren(node.children, run)
      };
    case "loop":
      return projectLoopNode(node, run);
    case "branch":
      return projectBranchNode(node, run);
    case "agent":
      return projectAgentNode(node, run);
    case "message":
      return projectMessageNode(node, run);
    case "human":
      return projectHumanNode(node, run);
    case "await":
      return projectAwaitNode(node, run);
    case "script":
      return projectScriptNode(node, run);
    case "check":
      return projectCheckNode(node, run);
    case "transform":
      return projectTransformNode(node, run);
    case "sleep":
      return projectSleepNode(node, run);
    case "end":
      return projectEndNode(node, run);
    case "sequence":
      return {
        id: node.id ?? "sequence",
        kind: "sequence",
        label: node.id ?? "sequence",
        status: statusForNode(run, node.id),
        children: projectChildren(node.children, run)
      };
  }
}

function projectLoopNode(node: WorkflowLoopNode, run: WorkflowRunRecord): WorkflowFlowProjectionNode {
  const children = projectChildren(node.children, run);
  const iteration = run.loopIterations[node.id] ?? 0;
  return {
    id: node.id,
    kind: "loop",
    label: node.id,
    status: statusForLoop(run, node.id, iteration, children),
    loop: {
      iteration,
      max: node.max,
      while: node.while,
      counterLabel: node.counterLabel
    },
    children
  };
}

function projectBranchNode(node: WorkflowBranchNode, run: WorkflowRunRecord): WorkflowFlowProjectionNode {
  return {
    id: node.id ?? "branch",
    kind: "branch",
    label: node.id ?? "branch",
    status: statusForNode(run, node.id),
    branch: {
      on: node.on,
      cases: node.cases.map((branchCase) => ({ ...branchCase })),
      defaultTarget: node.defaultTarget
    }
  };
}

function projectAgentNode(node: WorkflowAgentNode, run: WorkflowRunRecord): WorkflowFlowProjectionNode {
  return {
    id: node.id,
    kind: "agent",
    label: node.id,
    status: statusForNode(run, node.id),
    agent: {
      tool: node.tool,
      role: node.role,
      shortName: node.shortName,
      inputs: (node.inputs ?? []).map((input) => ({ ...input }))
    }
  };
}

function projectMessageNode(node: WorkflowMessageNode, run: WorkflowRunRecord): WorkflowFlowProjectionNode {
  return {
    id: node.id ?? `message:${node.target}`,
    kind: "message",
    label: node.id ?? `message:${node.target}`,
    status: statusForNode(run, node.id),
    message: {
      target: node.target,
      shortName: node.shortName
    }
  };
}

function projectHumanNode(node: WorkflowHumanNode, run: WorkflowRunRecord): WorkflowFlowProjectionNode {
  return {
    id: node.id ?? "human",
    kind: "human",
    label: node.id ?? "human",
    status: statusForNode(run, node.id),
    human: {
      artifact: node.artifact,
      schema: node.schema
    }
  };
}

function projectAwaitNode(node: WorkflowAwaitNode, run: WorkflowRunRecord): WorkflowFlowProjectionNode {
  return {
    id: node.id ?? `await:${node.on}`,
    kind: "await",
    label: node.id ?? `await:${node.on}`,
    status: statusForNode(run, node.id),
    await: {
      on: node.on
    }
  };
}

function projectScriptNode(node: WorkflowScriptNode, run: WorkflowRunRecord): WorkflowFlowProjectionNode {
  return {
    id: node.id ?? `script:${node.uses}`,
    kind: "script",
    label: node.id ?? `script:${node.uses}`,
    status: statusForNode(run, node.id),
    script: {
      uses: node.uses
    }
  };
}

function projectCheckNode(node: WorkflowCheckNode, run: WorkflowRunRecord): WorkflowFlowProjectionNode {
  return {
    id: node.id ?? `check:${node.uses}`,
    kind: "check",
    label: node.id ?? `check:${node.uses}`,
    status: statusForNode(run, node.id),
    script: {
      uses: node.uses
    }
  };
}

function projectTransformNode(node: WorkflowTransformNode, run: WorkflowRunRecord): WorkflowFlowProjectionNode {
  return {
    id: node.id ?? `transform:${node.to}`,
    kind: "transform",
    label: node.id ?? `transform:${node.to}`,
    status: statusForNode(run, node.id),
    transform: {
      from: node.from,
      to: node.to,
      uses: node.uses
    }
  };
}

function projectSleepNode(node: WorkflowSleepNode, run: WorkflowRunRecord): WorkflowFlowProjectionNode {
  return {
    id: node.id ?? `sleep:${node.durationMs}`,
    kind: "sleep",
    label: node.id ?? `sleep:${node.durationMs}`,
    status: statusForNode(run, node.id),
    sleep: {
      durationMs: node.durationMs
    }
  };
}

function projectEndNode(node: WorkflowEndNode, run: WorkflowRunRecord): WorkflowFlowProjectionNode {
  return {
    id: node.id ?? "end",
    kind: "end",
    label: node.id ?? "end",
    status: statusForNode(run, node.id)
  };
}

function statusForNode(run: WorkflowRunRecord, nodeId: string | undefined): RuntimeStatus {
  if (nodeId === undefined) {
    return "pending";
  }
  if (latestFailedEventIndex(run, nodeId) !== undefined) {
    return "failed";
  }
  const latestStarted = latestEventIndex(run, nodeId, "vertex.started");
  const latestCompleted = latestEventIndex(run, nodeId, "vertex.completed");
  if (latestCompleted !== undefined && (latestStarted === undefined || latestCompleted >= latestStarted)) {
    return "completed";
  }
  if (latestStarted !== undefined || run.nodeRunIds[nodeId] !== undefined) {
    return "running";
  }
  return "pending";
}

function statusForLoop(
  run: WorkflowRunRecord,
  nodeId: string,
  iteration: number,
  children: WorkflowFlowProjectionNode[]
): RuntimeStatus {
  const ownStatus = statusForNode(run, nodeId);
  if (ownStatus === "failed") {
    return "failed";
  }
  if (children.some((child) => child.status === "failed")) {
    return "failed";
  }
  if (children.some((child) => child.status === "running")) {
    return "running";
  }
  if (ownStatus === "running") {
    return "running";
  }
  if (iteration > 0 && children.some((child) => child.status !== "completed")) {
    return "running";
  }
  return ownStatus;
}

function latestEventIndex(run: WorkflowRunRecord, nodeId: string, type: string): number | undefined {
  let latest: number | undefined;
  for (const event of run.events) {
    if (event.type !== type) {
      continue;
    }
    if ((event.data as { vertexId?: string } | undefined)?.vertexId !== nodeId) {
      continue;
    }
    latest = event.index;
  }
  return latest;
}

function latestFailedEventIndex(run: WorkflowRunRecord, nodeId: string): number | undefined {
  return latestEventIndex(run, nodeId, "vertex.failed");
}
