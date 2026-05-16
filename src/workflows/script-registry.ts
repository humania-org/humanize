export type ScriptAdapterKind = "script" | "check" | "transform";

export interface ScriptAdapterDescriptor {
  id: string;
  kinds: readonly ScriptAdapterKind[];
  emitsArtifacts: readonly string[];
  emitsEvents: readonly string[];
  exitSemantics: "success-event" | "failure-raises";
}

export interface ScriptRegistry {
  register(descriptor: ScriptAdapterDescriptor): void;
  get(id: string): ScriptAdapterDescriptor | undefined;
  has(id: string): boolean;
  list(): ScriptAdapterDescriptor[];
}

class DefaultScriptRegistry implements ScriptRegistry {
  private readonly descriptors = new Map<string, ScriptAdapterDescriptor>();

  register(descriptor: ScriptAdapterDescriptor): void {
    if (descriptor.id.length === 0) {
      throw new Error("script adapter id must be non-empty");
    }
    this.descriptors.set(descriptor.id, {
      ...descriptor,
      kinds: [...descriptor.kinds],
      emitsArtifacts: [...descriptor.emitsArtifacts],
      emitsEvents: [...descriptor.emitsEvents]
    });
  }

  get(id: string): ScriptAdapterDescriptor | undefined {
    const descriptor = this.descriptors.get(id);
    return descriptor === undefined
      ? undefined
      : {
        ...descriptor,
        kinds: [...descriptor.kinds],
        emitsArtifacts: [...descriptor.emitsArtifacts],
        emitsEvents: [...descriptor.emitsEvents]
      };
  }

  has(id: string): boolean {
    return this.descriptors.has(id);
  }

  list(): ScriptAdapterDescriptor[] {
    return [...this.descriptors.values()].map((descriptor) => ({
      ...descriptor,
      kinds: [...descriptor.kinds],
      emitsArtifacts: [...descriptor.emitsArtifacts],
      emitsEvents: [...descriptor.emitsEvents]
    }));
  }
}

export function createScriptRegistry(): ScriptRegistry {
  return new DefaultScriptRegistry();
}

export function createDefaultScriptRegistry(): ScriptRegistry {
  const registry = createScriptRegistry();
  for (const descriptor of DEFAULT_SCRIPT_ADAPTERS) {
    registry.register(descriptor);
  }
  return registry;
}

const DEFAULT_SCRIPT_ADAPTERS: readonly ScriptAdapterDescriptor[] = Object.freeze([
  adapter("test.pass", ["script", "check"]),
  adapter("test.run", ["script", "check"]),
  adapter("test.copy", ["transform"]),
  adapter("git.statusClean", ["check"]),
  adapter("git.detectBase", ["check"]),
  adapter("codex.review", ["check"]),
  adapter("humanize.validateRefinePlanInput", ["check"]),
  adapter("humanize.extractPlanComments", ["check"], [], ["plan.comments.extracted"]),
  adapter("humanize.validateIdeaInput", ["check"]),
  adapter("humanize.validatePlanInput", ["check"]),
  adapter("humanize.resolveProjectConfig", ["check"], [], ["project.config.resolved"]),
  adapter("plan.extractComments", ["transform"]),
  adapter("idea.collectProposalStatus", ["transform"]),
  adapter("rlcr.initializeGoalTracker", ["transform"]),
  adapter("rlcr.updateLoopStatus", ["transform"])
]);

function adapter(
  id: string,
  kinds: readonly ScriptAdapterKind[],
  emitsArtifacts: readonly string[] = [],
  emitsEvents: readonly string[] = []
): ScriptAdapterDescriptor {
  return {
    id,
    kinds,
    emitsArtifacts,
    emitsEvents,
    exitSemantics: "failure-raises"
  };
}
