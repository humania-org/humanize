export function parseJsonLines(output: string): unknown[] {
  const events: unknown[] = [];

  for (const line of output.split(/\r?\n/)) {
    const trimmedLine = line.trim();
    if (trimmedLine.length === 0) {
      continue;
    }

    try {
      events.push(JSON.parse(trimmedLine));
    } catch {
      continue;
    }
  }

  return events;
}

export function extractBackendSessionId(events: unknown[]): string | undefined {
  for (const event of events) {
    const sessionId = findSessionId(event);
    if (sessionId !== undefined) {
      return sessionId;
    }
  }

  return undefined;
}

export function extractBackendSessionIdFromText(text: string): string | undefined {
  return extractBackendSessionId(parseJsonLines(text));
}

function findSessionId(value: unknown, depth = 0): string | undefined {
  if (depth > 4 || value === null || typeof value !== "object") {
    return undefined;
  }

  const record = value as Record<string, unknown>;
  for (const key of ["session_id", "sessionId", "thread_id", "threadId"]) {
    const item = record[key];
    if (typeof item === "string" && item.length > 0) {
      return item;
    }
  }

  for (const item of Object.values(record)) {
    const nested = findSessionId(item, depth + 1);
    if (nested !== undefined) {
      return nested;
    }
  }

  return undefined;
}
