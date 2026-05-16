/**
 * v0.1 artifact schema registry.
 *
 * A schema is a named validator. Validators may be Zod-style (safeParse(content)
 * returning { success: boolean; error?: ... }), JSON-Schema-style (validate(content)
 * returning boolean or an object with errors), or any function that accepts the
 * content and either returns / resolves cleanly or throws. The registry hides the
 * dialect; callers see validate(name, content) which returns one of:
 *
 * - { status: "accepted" }: schema is registered and content matched the validator.
 * - { status: "schema-mismatch", detail? }: schema is registered but content failed.
 * - { status: "unregistered" }: schema name has no registered validator.
 *
 * Cartridges may not register new schemas at load time; registration happens at
 * hub startup or by first-party flow modules.
 */

export type SchemaValidationOutcome =
  | { status: "accepted" }
  | { status: "schema-mismatch"; detail?: string }
  | { status: "unregistered" };

export interface ZodLikeValidator {
  safeParse(value: unknown): { success: boolean; error?: { message?: string; issues?: unknown[] } };
}

export interface JsonSchemaLikeValidator {
  validate(value: unknown): boolean | { valid: boolean; errors?: unknown };
}

export type FunctionValidator = (value: unknown) => void | boolean | Promise<void | boolean>;

export type SchemaValidator =
  | ZodLikeValidator
  | JsonSchemaLikeValidator
  | FunctionValidator;

export interface SchemaRegistry {
  register(name: string, validator: SchemaValidator): void;
  has(name: string): boolean;
  validate(name: string, content: unknown): SchemaValidationOutcome;
  list(): string[];
}

class DefaultSchemaRegistry implements SchemaRegistry {
  private readonly validators = new Map<string, SchemaValidator>();

  register(name: string, validator: SchemaValidator): void {
    if (name.length === 0) {
      throw new Error("schema name must be non-empty");
    }
    this.validators.set(name, validator);
  }

  has(name: string): boolean {
    return this.validators.has(name);
  }

  validate(name: string, content: unknown): SchemaValidationOutcome {
    const validator = this.validators.get(name);
    if (validator === undefined) {
      return { status: "unregistered" };
    }
    return runValidator(validator, content);
  }

  list(): string[] {
    return [...this.validators.keys()];
  }
}

export function createSchemaRegistry(): SchemaRegistry {
  return new DefaultSchemaRegistry();
}

/**
 * Build the v0.1 default registry. The first-party flow cartridges reference
 * a small set of schema names; rather than couple the registry to each flow's
 * structured shape (which would require importing flow packages here), we
 * register permissive validators that accept any structured content. Flow
 * authors that need stricter validation may register a typed validator before
 * starting the workflow.
 */
export function createDefaultSchemaRegistry(): SchemaRegistry {
  const registry = createSchemaRegistry();
  for (const name of DEFAULT_SCHEMA_NAMES) {
    registry.register(name, DEFAULT_SCHEMA_VALIDATORS[name] ?? nonUndefined);
  }
  return registry;
}

const DEFAULT_SCHEMA_VALIDATORS: Record<string, FunctionValidator> = {
  "route.v1": (value) => {
    const object = requireRecord(value);
    requireString(object.next, "next");
  },
  "quiz.v1": (value) => {
    requireRecord(value);
  },
  "team.workerResult.v1": (value) => {
    const object = requireRecord(value);
    requireString(object.status, "status");
  },
  "team.captainResult.v1": (value) => {
    const object = requireRecord(value);
    requireString(object.status, "status");
  },
  "plan.verdict.v1": (value) => {
    const object = requireRecord(value);
    requireString(object.status, "status");
  },
  "rlcr.verdict.v1": (value) => {
    const object = requireRecord(value);
    const status = requireString(object.status, "status");
    if (!["revise", "complete", "stop"].includes(status)) {
      throw new Error("status must be revise, complete, or stop");
    }
  },
  "rlcr.codeReview.v1": (value) => {
    const object = requireRecord(value);
    requireString(object.status, "status");
  }
};

/**
 * Schema names referenced by bundled cartridges. Keep this in sync with
 * the flow/<id>/workflow.html files. Adding a new built-in schema is a
 * hub-level change, mirroring the script-registry rule.
 */
const DEFAULT_SCHEMA_NAMES: readonly string[] = Object.freeze([
  // Generic / smoke test schemas.
  "result.v1",
  "team.workerResult.v1",
  "team.captainResult.v1",
  "team.board.v1",
  "score.v1",
  "quiz.v1",
  "route.v1",
  "snapshot.v1",
  "done.v1",
  // First-party gen-plan schemas.
  "plan.draft.v1",
  "plan.relevance.v1",
  "plan.analysis.v1",
  "plan.candidate.v1",
  "plan.verdict.v1",
  "plan.final.v1",
  "plan.convergence.v1",
  "plan.humanDecision.v1",
  // First-party gen-idea schemas.
  "idea.input.v1",
  "idea.directions.v1",
  "idea.proposal.v1",
  "idea.draft.v1",
  "idea.scoreboard.v1",
  // First-party refine-plan schemas.
  "plan.annotated.v1",
  "plan.comments.v1",
  "plan.refined.v1",
  "plan.qa.v1",
  "plan.commentLedger.v1",
  // First-party RLCR schemas.
  "rlcr.plan.v1",
  "rlcr.planCompliance.v1",
  "rlcr.quiz.v1",
  "rlcr.quizAnswer.v1",
  "rlcr.summary.v1",
  "rlcr.verdict.v1",
  "rlcr.codeReview.v1",
  "rlcr.final.v1",
  "rlcr.goalTracker.v1",
  "rlcr.loopStatus.v1",
  // Dashboard-side schemas.
  "dashboard.board.v1"
]);

function runValidator(validator: SchemaValidator, content: unknown): SchemaValidationOutcome {
  // Zod-style validator (has safeParse).
  if (isZodLike(validator)) {
    const result = validator.safeParse(content);
    if (result.success) {
      return { status: "accepted" };
    }
    return { status: "schema-mismatch", detail: result.error?.message };
  }
  // JSON-Schema-style validator (has validate).
  if (isJsonSchemaLike(validator)) {
    const result = validator.validate(content);
    if (typeof result === "boolean") {
      return result ? { status: "accepted" } : { status: "schema-mismatch" };
    }
    return result.valid
      ? { status: "accepted" }
      : { status: "schema-mismatch", detail: result.errors === undefined ? undefined : safeStringify(result.errors) };
  }
  // Plain function validator: throws on failure, returns falsy on failure, or
  // returns/resolves with anything truthy / undefined on success.
  try {
    const outcome = validator(content);
    if (outcome instanceof Promise) {
      // For v0.1 we treat async validators as synchronous: if the caller wants
      // strict async validation it should register a Zod or JSON-Schema validator.
      // Reaching this path means the function didn't throw synchronously; we
      // optimistically treat that as accepted. Failures in the pending promise
      // are not observed at deliver time.
      return { status: "accepted" };
    }
    if (outcome === false) {
      return { status: "schema-mismatch" };
    }
    return { status: "accepted" };
  } catch (error) {
    return {
      status: "schema-mismatch",
      detail: error instanceof Error ? error.message : String(error)
    };
  }
}

function nonUndefined(value: unknown): void {
  if (value === undefined) {
    throw new Error("artifact content must not be undefined");
  }
}

function requireRecord(value: unknown): Record<string, unknown> {
  if (value === undefined || value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("artifact content must be an object");
  }
  return value as Record<string, unknown>;
}

function requireString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${field} must be a non-empty string`);
  }
  return value;
}

function isZodLike(validator: SchemaValidator): validator is ZodLikeValidator {
  return typeof validator === "object" && validator !== null && "safeParse" in validator && typeof (validator as ZodLikeValidator).safeParse === "function";
}

function isJsonSchemaLike(validator: SchemaValidator): validator is JsonSchemaLikeValidator {
  return typeof validator === "object" && validator !== null && "validate" in validator && typeof (validator as JsonSchemaLikeValidator).validate === "function";
}

function safeStringify(value: unknown): string | undefined {
  try {
    return JSON.stringify(value);
  } catch {
    return undefined;
  }
}
