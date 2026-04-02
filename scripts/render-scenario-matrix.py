#!/usr/bin/env python3
"""
Generate a local HTML dashboard for a Humanize scenario matrix snapshot.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from html import escape
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from typing import Any
from urllib.parse import urlparse


def die(message: str) -> int:
    print(f"[scenario-matrix-view] Error: {message}", file=sys.stderr)
    return 1


def read_state_value(state_file: Path, key: str) -> str:
    if not state_file.is_file():
        return ""

    try:
        for line in state_file.read_text(encoding="utf-8").splitlines():
            if line.startswith(f"{key}:"):
                return line.split(":", 1)[1].strip().strip('"')
    except OSError:
        return ""
    return ""


def git_project_root(start: Path) -> Path | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(start), "rev-parse", "--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    root = result.stdout.strip()
    return Path(root) if root else None


def project_root_from_session(session_dir: Path) -> Path:
    try:
        return session_dir.resolve().parents[2]
    except IndexError:
        return session_dir.resolve()


def find_latest_session(loop_dir: Path) -> Path | None:
    if not loop_dir.is_dir():
        return None

    latest: Path | None = None
    for child in loop_dir.iterdir():
        if child.is_dir() and len(child.name) == 19 and child.name[4] == "-" and child.name[7] == "-" and child.name[10] == "_":
            if latest is None or child.name > latest.name:
                latest = child
    return latest


def resolve_matrix_from_session(session_dir: Path) -> tuple[Path, Path]:
    state_candidates = [
        session_dir / "state.md",
        session_dir / "methodology-analysis-state.md",
        session_dir / "finalize-state.md",
    ]
    state_candidates.extend(sorted(session_dir.glob("*-state.md")))
    state_file = next((candidate for candidate in state_candidates if candidate.is_file()), session_dir / "state.md")

    matrix_rel = read_state_value(state_file, "scenario_matrix_file")
    matrix_file: Path | None = None
    if matrix_rel:
        matrix_candidate = project_root_from_session(session_dir) / matrix_rel
        if matrix_candidate.is_file():
            matrix_file = matrix_candidate

    if matrix_file is None:
        fallback = session_dir / "scenario-matrix.json"
        if fallback.is_file():
            matrix_file = fallback

    if matrix_file is None:
        raise FileNotFoundError(f"no scenario matrix found for session: {session_dir}")
    return matrix_file, session_dir


def resolve_input(input_arg: str | None) -> tuple[Path, Path | None]:
    if input_arg:
        candidate = Path(input_arg).expanduser()
    else:
        base = Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
        project_root = git_project_root(base) or base.resolve()
        latest = find_latest_session(project_root / ".humanize" / "rlcr")
        if latest is None:
            raise FileNotFoundError("no RLCR session found under .humanize/rlcr")
        return resolve_matrix_from_session(latest)

    candidate = candidate.resolve()

    if candidate.is_file():
        if candidate.suffix.lower() == ".json":
            return candidate, candidate.parent if candidate.name == "scenario-matrix.json" else None
        if candidate.name.endswith("-state.md") or candidate.name == "state.md":
            return resolve_matrix_from_session(candidate.parent)
        raise FileNotFoundError(f"unsupported input file: {candidate}")

    if candidate.is_dir():
        if (candidate / ".humanize" / "rlcr").is_dir():
            latest = find_latest_session(candidate / ".humanize" / "rlcr")
            if latest is None:
                raise FileNotFoundError(f"no RLCR session found under {candidate / '.humanize' / 'rlcr'}")
            return resolve_matrix_from_session(latest)
        if (candidate / "scenario-matrix.json").is_file():
            return resolve_matrix_from_session(candidate)
        if (candidate / "state.md").is_file() or list(candidate.glob("*-state.md")):
            return resolve_matrix_from_session(candidate)
        raise FileNotFoundError(f"directory is not a session dir, project dir, or matrix dir: {candidate}")

    raise FileNotFoundError(f"input path not found: {candidate}")


def choose_output_path(matrix_file: Path, session_dir: Path | None, explicit_output: str | None) -> Path:
    if explicit_output:
        return Path(explicit_output).expanduser().resolve()

    if matrix_file.name == "scenario-matrix.json":
        filename = "scenario-matrix-view.html"
    else:
        filename = f"{matrix_file.stem}-view.html"

    base_dir = session_dir if session_dir is not None else matrix_file.parent
    return (base_dir / filename).resolve()


def load_matrix(matrix_file: Path) -> dict[str, Any]:
    try:
        matrix = json.loads(matrix_file.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise FileNotFoundError(f"matrix file does not exist: {matrix_file}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON in {matrix_file}: {exc}") from exc

    if not isinstance(matrix, dict):
        raise ValueError("matrix root must be a JSON object")
    if not isinstance(matrix.get("tasks"), list):
        raise ValueError("matrix.tasks must be an array")
    return matrix


def classify_bucket(task: dict[str, Any], primary_id: str | None, supporting_ids: set[str]) -> str:
    task_id = str(task.get("id") or "")
    state = str(task.get("state") or "pending")
    if state == "done":
        return "done"
    if state == "deferred" or str(task.get("admission", {}).get("status") or "") == "deferred":
        return "deferred"
    if task_id and task_id == primary_id:
        return "primary"
    if task_id in supporting_ids:
        return "supporting"
    return "active"


def should_render_task(raw_task: Any) -> tuple[bool, str | None]:
    if not isinstance(raw_task, dict):
        return False, "invalid task entry"

    task_id = str(raw_task.get("id") or "").strip()
    title = raw_task.get("title")
    source = str(raw_task.get("source") or "").strip().lower()
    normalized_title = " ".join(str(title or "").split()).upper()

    if not task_id:
        return False, "missing task id"
    if not isinstance(title, str) or not title.strip():
        return False, f"{task_id}: missing task title"
    if normalized_title in {"FINDING", "STRUCTURED_FINDING", "WATCHLIST_FINDING"}:
        return False, f"{task_id}: placeholder finding title"
    if task_id.startswith("finding-r") and source == "review":
        return False, f"{task_id}: transient review finding"
    return True, None


def build_view_model(matrix: dict[str, Any], matrix_file: Path, session_dir: Path | None) -> dict[str, Any]:
    raw_tasks = matrix.get("tasks", [])
    runtime = matrix.get("runtime", {})
    manager = matrix.get("manager", {})
    checkpoint = runtime.get("checkpoint", {})
    convergence = runtime.get("convergence", {})
    oversight = matrix.get("oversight", {})
    feedback = matrix.get("feedback", {})
    events = matrix.get("events", [])

    primary_id = manager.get("current_primary_task_id") or checkpoint.get("primary_task_id")
    supporting_ids = {
        str(task_id)
        for task_id in checkpoint.get("supporting_task_ids", [])
        if isinstance(task_id, str)
    }

    tasks: list[dict[str, Any]] = []
    hidden_tasks: list[str] = []
    for raw_task in raw_tasks:
        should_render, reason = should_render_task(raw_task)
        if should_render:
            tasks.append(raw_task)
        elif reason:
            hidden_tasks.append(reason)

    dependents: dict[str, list[str]] = defaultdict(list)
    for task in tasks:
        task_id = str(task.get("id") or "")
        for dep in task.get("depends_on", []):
            if isinstance(dep, str) and task_id:
                dependents[dep].append(task_id)

    feedback_entries = list(feedback.get("execution", [])) + list(feedback.get("review", []))
    feedback_by_task: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for entry in feedback_entries:
        task_id = str(entry.get("task_id") or "")
        if task_id:
            feedback_by_task[task_id].append(entry)

    state_counts = Counter()
    bucket_counts = Counter()
    task_cards = []
    for raw_task in tasks:
        task_id = str(raw_task.get("id") or "")
        bucket = classify_bucket(raw_task, primary_id, supporting_ids)
        state = str(raw_task.get("state") or "pending")
        state_counts[state] += 1
        bucket_counts[bucket] += 1
        task_cards.append(
            {
                "id": task_id,
                "title": str(raw_task.get("title") or "Untitled task"),
                "lane": str(raw_task.get("lane") or "queued"),
                "routing": str(raw_task.get("routing") or "coding"),
                "state": state,
                "kind": str(raw_task.get("kind") or "feature"),
                "bucket": bucket,
                "is_primary": task_id == primary_id,
                "is_supporting": task_id in supporting_ids,
                "risk_bucket": str(raw_task.get("risk_bucket") or "planned"),
                "owner": raw_task.get("owner"),
                "target_ac": raw_task.get("target_ac", []),
                "depends_on": raw_task.get("depends_on", []),
                "dependent_ids": sorted(dependents.get(task_id, [])),
                "cluster_id": raw_task.get("cluster_id"),
                "repair_wave": raw_task.get("repair_wave"),
                "wave_label": raw_task.get("repair_wave") or raw_task.get("cluster_id"),
                "scope": raw_task.get("scope", {}),
                "assumptions": raw_task.get("assumptions", []),
                "strategy": raw_task.get("strategy", {}),
                "health": raw_task.get("health", {}),
                "admission": raw_task.get("admission", {}),
                "metadata": raw_task.get("metadata", {}),
                "feedback": feedback_by_task.get(task_id, []),
            }
        )

    task_cards.sort(
        key=lambda task: (
            {"primary": 0, "supporting": 1, "active": 2, "done": 3, "deferred": 4}.get(task["bucket"], 9),
            {"in_progress": 0, "ready": 1, "pending": 2, "blocked": 3, "needs_replan": 4, "done": 5, "deferred": 6}.get(task["state"], 9),
            task["id"],
        )
    )

    primary_task = next((task for task in task_cards if task["id"] == primary_id), None)
    event_cards = []
    for event in events:
        if not isinstance(event, dict):
            continue
        event_cards.append(
            {
                "id": str(event.get("id") or ""),
                "type": str(event.get("type") or "event"),
                "round": event.get("round"),
                "phase": event.get("phase"),
                "task_id": event.get("task_id"),
                "verdict": event.get("verdict"),
                "severity": event.get("severity"),
                "finding_key": event.get("finding_key"),
                "created_at": event.get("created_at"),
                "summary": event.get("summary") or event.get("reason") or event.get("message"),
            }
        )
    event_cards.sort(key=lambda event: (str(event.get("created_at") or ""), event.get("id", "")), reverse=True)

    return {
        "meta": {
            "title": "Scenario Matrix Dashboard",
            "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "source_file": str(matrix_file),
            "session_dir": str(session_dir) if session_dir else "",
            "schema_version": matrix.get("schema_version"),
        },
        "plan": matrix.get("plan", {}),
        "metadata": matrix.get("metadata", {}),
        "summary": {
            "mode": runtime.get("mode"),
            "projection_mode": runtime.get("projection_mode"),
            "current_round": runtime.get("current_round"),
            "primary_task_id": primary_id,
            "primary_task_title": primary_task["title"] if primary_task else None,
            "task_count": len(task_cards),
            "hidden_task_count": len(hidden_tasks),
            "state_counts": state_counts,
            "bucket_counts": bucket_counts,
            "event_count": len(event_cards),
            "execution_feedback_count": len(feedback.get("execution", [])),
            "review_feedback_count": len(feedback.get("review", [])),
        },
        "checkpoint": checkpoint,
        "convergence": convergence,
        "last_review": runtime.get("last_review", {}),
        "manager": manager,
        "oversight": oversight,
        "tasks": task_cards,
        "hidden_tasks": hidden_tasks,
        "events": event_cards,
        "feedback": {
            "execution": feedback.get("execution", []),
            "review": feedback.get("review", []),
        },
        "raw_matrix": matrix,
    }


def load_view_model_from_input(input_arg: str | None) -> tuple[dict[str, Any], Path, Path | None]:
    matrix_file, session_dir = resolve_input(input_arg)
    matrix = load_matrix(matrix_file)
    return build_view_model(matrix, matrix_file, session_dir), matrix_file, session_dir


def render_html(view_model: dict[str, Any], page_title: str) -> str:
    payload = json.dumps(view_model, ensure_ascii=False).replace("</", "<\\/")
    html_title = escape(page_title)
    source_file = escape(view_model["meta"]["source_file"])
    generated_at = escape(view_model["meta"]["generated_at"])
    session_dir = escape(view_model["meta"].get("session_dir", "") or "n/a")
    template = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>__TITLE__</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f5f1e8;
      --panel: rgba(255, 252, 245, 0.96);
      --panel-strong: #fffdf7;
      --ink: #20323f;
      --muted: #637180;
      --line: rgba(32, 50, 63, 0.12);
      --accent: #0f6d6a;
      --accent-soft: rgba(15, 109, 106, 0.12);
      --warm: #c36c2f;
      --warn: #be6a0f;
      --danger: #ba3a2c;
      --ok: #3d7a3b;
      --shadow: 0 16px 40px rgba(32, 50, 63, 0.08);
    }

    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Iosevka Etoile", "IBM Plex Sans", "Segoe UI", sans-serif;
      background:
        radial-gradient(circle at top left, rgba(15, 109, 106, 0.10), transparent 28rem),
        radial-gradient(circle at top right, rgba(195, 108, 47, 0.12), transparent 26rem),
        linear-gradient(180deg, #f8f4ea 0%, var(--bg) 100%);
      color: var(--ink);
    }

    a { color: var(--accent); }
    code, pre, .mono {
      font-family: "Iosevka Term", "SFMono-Regular", Consolas, monospace;
    }

    .page {
      width: min(1560px, calc(100vw - 40px));
      margin: 24px auto 48px;
      display: grid;
      gap: 20px;
    }

    .hero, .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 22px;
      box-shadow: var(--shadow);
    }

    .hero {
      padding: 26px 28px;
      display: grid;
      gap: 16px;
    }

    .hero-top {
      display: flex;
      justify-content: space-between;
      gap: 20px;
      align-items: start;
    }

    .hero h1 {
      margin: 0;
      font-size: clamp(2rem, 4vw, 3rem);
      letter-spacing: -0.04em;
      line-height: 0.92;
    }

    .hero p {
      margin: 0;
      max-width: 60rem;
      color: var(--muted);
      line-height: 1.45;
    }

    .meta-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
      gap: 12px;
    }

    .meta-card {
      background: var(--panel-strong);
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 14px 16px;
      min-height: 96px;
    }

    .meta-card small {
      display: block;
      font-size: 0.78rem;
      letter-spacing: 0.06em;
      text-transform: uppercase;
      color: var(--muted);
      margin-bottom: 8px;
    }

    .meta-card strong {
      display: block;
      font-size: 1.18rem;
      line-height: 1.15;
      margin-bottom: 6px;
    }

    .meta-card span {
      color: var(--muted);
      line-height: 1.35;
      font-size: 0.95rem;
    }

    .workspace {
      display: grid;
      grid-template-columns: minmax(0, 1.65fr) minmax(340px, 0.95fr);
      gap: 20px;
      align-items: start;
    }

    .panel {
      padding: 18px 18px 20px;
    }

    .panel h2, .panel h3 {
      margin: 0 0 10px;
      letter-spacing: -0.03em;
    }

    .panel-header {
      display: flex;
      justify-content: space-between;
      gap: 10px;
      align-items: baseline;
      margin-bottom: 14px;
    }

    .panel-header p {
      margin: 0;
      color: var(--muted);
      font-size: 0.95rem;
    }

    .graph-shell {
      border: 1px solid var(--line);
      border-radius: 20px;
      background: rgba(255, 255, 255, 0.54);
      overflow: hidden;
    }

    .graph-toolbar {
      display: flex;
      justify-content: space-between;
      gap: 12px;
      align-items: center;
      padding: 12px 14px;
      border-bottom: 1px solid var(--line);
      background: rgba(255, 255, 255, 0.72);
    }

    .graph-toolbar p {
      margin: 0;
      color: var(--muted);
      font-size: 0.93rem;
      line-height: 1.4;
      max-width: 56rem;
    }

    .graph-actions {
      display: flex;
      gap: 8px;
      align-items: center;
      flex-wrap: wrap;
    }

    .graph-zoom {
      display: flex;
      align-items: center;
      gap: 8px;
      padding-right: 6px;
      margin-right: 6px;
      border-right: 1px solid var(--line);
    }

    .graph-refresh {
      display: flex;
      align-items: center;
      gap: 8px;
      padding-right: 6px;
      margin-right: 6px;
      border-right: 1px solid var(--line);
    }

    .zoom-label {
      min-width: 4.3rem;
      text-align: center;
      font-size: 0.84rem;
      color: var(--muted);
    }

    .refresh-label {
      min-width: 4.8rem;
      text-align: center;
      font-size: 0.84rem;
      color: var(--muted);
    }

    .graph-button {
      appearance: none;
      border: 1px solid rgba(32, 50, 63, 0.16);
      background: #fffefb;
      color: var(--ink);
      border-radius: 999px;
      padding: 8px 14px;
      font: inherit;
      font-size: 0.9rem;
      cursor: pointer;
      transition: background 120ms ease, border-color 120ms ease, transform 120ms ease;
    }

    .graph-button:hover {
      background: rgba(15, 109, 106, 0.08);
      border-color: rgba(15, 109, 106, 0.28);
      transform: translateY(-1px);
    }

    .graph-button:active {
      transform: translateY(0);
    }

    .graph-viewport {
      position: relative;
      overflow: hidden;
      min-height: 820px;
      max-height: 84vh;
      cursor: grab;
      background:
        linear-gradient(transparent 31px, rgba(32, 50, 63, 0.05) 32px),
        linear-gradient(90deg, transparent 31px, rgba(32, 50, 63, 0.05) 32px),
        linear-gradient(180deg, rgba(255, 255, 255, 0.72), rgba(255, 255, 255, 0.58));
      background-size: 32px 32px, 32px 32px, auto;
      overscroll-behavior: contain;
      touch-action: none;
    }

    .graph-viewport.is-panning {
      cursor: grabbing;
      user-select: none;
    }

    .graph-canvas {
      position: relative;
      min-width: 2360px;
      min-height: 980px;
      transform-origin: 0 0;
      will-change: transform;
    }

    .workflow-stage {
      position: absolute;
      top: 26px;
      bottom: 26px;
      border: 1px solid var(--line);
      border-radius: 24px;
      background: linear-gradient(180deg, rgba(255, 255, 255, 0.74) 0%, rgba(251, 247, 239, 0.56) 100%);
      box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.65);
      pointer-events: none;
      z-index: 0;
    }

    .workflow-stage-header {
      position: absolute;
      left: 20px;
      right: 20px;
      top: 18px;
      display: grid;
      gap: 6px;
    }

    .stage-label {
      color: var(--muted);
      font-size: 0.72rem;
      text-transform: uppercase;
      letter-spacing: 0.08em;
    }

    .stage-title {
      font-size: 1.08rem;
      line-height: 1.1;
      font-weight: 700;
      color: var(--ink);
    }

    .stage-subtitle {
      color: var(--muted);
      font-size: 0.88rem;
      line-height: 1.35;
      max-width: 24rem;
    }

    .stage-meta {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
    }

    .graph-links {
      position: absolute;
      inset: 0;
      pointer-events: none;
      overflow: visible;
      z-index: 1;
    }

    .task-card {
      background: linear-gradient(180deg, #fffefb 0%, #f6f2ea 100%);
      border: 1px solid rgba(32, 50, 63, 0.12);
      border-radius: 20px;
      padding: 16px 16px 15px;
      cursor: pointer;
      transition: box-shadow 120ms ease, border-color 120ms ease;
      box-shadow: 0 6px 20px rgba(32, 50, 63, 0.06);
    }

    .task-card:hover {
      box-shadow: 0 10px 24px rgba(32, 50, 63, 0.10);
    }

    .task-node {
      position: absolute;
      width: 340px;
      z-index: 3;
      touch-action: none;
      cursor: grab;
    }

    .task-node.dragging {
      z-index: 6;
      cursor: grabbing;
      box-shadow: 0 18px 34px rgba(15, 109, 106, 0.18);
    }

    .task-card.active {
      border-color: rgba(15, 109, 106, 0.55);
      box-shadow: 0 0 0 2px rgba(15, 109, 106, 0.15), 0 16px 30px rgba(15, 109, 106, 0.12);
    }

    .task-card.state-in_progress { border-left: 6px solid var(--accent); }
    .task-card.state-ready { border-left: 6px solid #4b86b4; }
    .task-card.state-pending { border-left: 6px solid #8a9baa; }
    .task-card.state-blocked { border-left: 6px solid var(--warn); }
    .task-card.state-needs_replan { border-left: 6px solid var(--danger); }
    .task-card.state-done { border-left: 6px solid var(--ok); }
    .task-card.state-deferred { border-left: 6px solid #7b6f63; }

    .task-id {
      font-size: 0.74rem;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      color: var(--muted);
      margin-bottom: 6px;
    }

    .task-title {
      margin: 0 0 10px;
      font-size: 1.06rem;
      line-height: 1.25;
      overflow-wrap: anywhere;
    }

    .badges, .mini-meta {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
      margin-bottom: 9px;
    }

    .badge {
      border-radius: 999px;
      padding: 4px 9px;
      font-size: 0.76rem;
      border: 1px solid var(--line);
      background: #fff;
      color: var(--ink);
    }

    .badge.primary { background: rgba(15, 109, 106, 0.10); border-color: rgba(15, 109, 106, 0.22); color: var(--accent); }
    .badge.supporting { background: rgba(195, 108, 47, 0.10); border-color: rgba(195, 108, 47, 0.22); color: var(--warm); }
    .badge.risk-high { background: rgba(186, 58, 44, 0.12); border-color: rgba(186, 58, 44, 0.25); color: var(--danger); }
    .badge.state-blocked, .badge.state-needs_replan { color: var(--danger); border-color: rgba(186, 58, 44, 0.28); background: rgba(186, 58, 44, 0.08); }
    .badge.state-ready, .badge.state-in_progress { color: var(--accent); border-color: rgba(15, 109, 106, 0.24); background: rgba(15, 109, 106, 0.08); }
    .badge.state-done { color: var(--ok); border-color: rgba(61, 122, 59, 0.26); background: rgba(61, 122, 59, 0.10); }

    .task-foot {
      color: var(--muted);
      font-size: 0.9rem;
      line-height: 1.42;
      overflow-wrap: anywhere;
    }

    .detail-panel {
      display: grid;
      gap: 16px;
    }

    .detail-card {
      border: 1px solid var(--line);
      border-radius: 18px;
      background: var(--panel-strong);
      padding: 16px;
    }

    .detail-card h3 {
      margin: 0 0 6px;
      font-size: 1.08rem;
    }

    .detail-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 10px;
      margin: 12px 0;
    }

    .detail-stat {
      border: 1px solid var(--line);
      border-radius: 14px;
      padding: 10px 12px;
      background: rgba(255, 255, 255, 0.66);
    }

    .detail-stat small {
      display: block;
      color: var(--muted);
      margin-bottom: 4px;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      font-size: 0.72rem;
    }

    .detail-stat strong {
      font-size: 1rem;
      line-height: 1.2;
    }

    .list, .timeline, .feedback-list {
      display: grid;
      gap: 10px;
    }

    .list-item, .timeline-item, .feedback-item {
      border: 1px solid var(--line);
      border-radius: 14px;
      padding: 10px 12px;
      background: rgba(255, 255, 255, 0.74);
    }

    .timeline-item strong, .feedback-item strong {
      display: block;
      margin-bottom: 4px;
    }

    .muted {
      color: var(--muted);
    }

    .warnings {
      display: grid;
      gap: 8px;
    }

    details.debug summary {
      cursor: pointer;
      font-weight: 600;
    }

    pre.raw-json {
      max-height: 360px;
      overflow: auto;
      background: #1c2833;
      color: #f5f7fa;
      border-radius: 16px;
      padding: 14px;
      font-size: 0.84rem;
      line-height: 1.42;
    }

    @media (max-width: 1380px) {
      .workspace {
        grid-template-columns: 1fr;
      }
    }

    @media (max-width: 1100px) {
      .graph-toolbar {
        flex-direction: column;
        align-items: flex-start;
      }
    }

    @media (max-width: 900px) {
      .page {
        width: min(100vw - 18px, 100%);
        margin: 12px auto 28px;
      }
      .hero, .panel {
        border-radius: 18px;
      }
      .hero-top {
        flex-direction: column;
      }
      .graph-viewport {
        min-height: 620px;
      }
      .detail-grid {
        grid-template-columns: 1fr;
      }
    }

    @media (max-width: 640px) {
      .graph-viewport {
        min-height: 520px;
      }
    }
  </style>
</head>
<body>
  <div class="page">
    <section class="hero">
      <div class="hero-top">
        <div>
          <h1>__TITLE__</h1>
          <p>Manager-facing snapshot of the current scenario matrix. This view groups tasks into the active frontier, shows dependency edges, exposes checkpoint and convergence status, and keeps feedback/events visible without forcing you to read raw JSON.</p>
        </div>
        <div class="muted mono">
          <div><strong>Generated:</strong> __GENERATED_AT__</div>
          <div><strong>Source:</strong> __SOURCE_FILE__</div>
          <div><strong>Session:</strong> __SESSION_DIR__</div>
        </div>
      </div>
      <div class="meta-grid" id="overview-cards"></div>
    </section>

    <div class="workspace">
      <section class="panel">
        <div class="panel-header">
          <div>
            <h2>Workflow Graph</h2>
            <p>Read the matrix as a left-to-right dependency chain, closer to a workflow graph than a stacked kanban board.</p>
          </div>
          <div class="muted mono" id="board-legend"></div>
        </div>
        <div class="graph-shell">
          <div class="graph-toolbar">
            <p>Tasks are staged from left to right by dependency depth. Drag cards to refine local branches, drag the background to pan, and use reset if you want the workflow chain rebuilt from the current matrix.</p>
            <div class="graph-actions">
              <div class="graph-zoom">
                <button class="graph-button" id="zoom-out" type="button">-</button>
                <div class="zoom-label mono" id="zoom-label">100%</div>
                <button class="graph-button" id="zoom-in" type="button">+</button>
                <button class="graph-button" id="zoom-fit" type="button">Fit</button>
              </div>
              <div class="graph-refresh">
                <button class="graph-button" id="auto-refresh-toggle" type="button">Auto Refresh: On</button>
                <div class="refresh-label mono" id="auto-refresh-label">60s</div>
              </div>
              <button class="graph-button" id="refresh-view" type="button">Refresh Snapshot</button>
              <button class="graph-button" id="reset-layout" type="button">Reset Layout</button>
            </div>
          </div>
          <div class="graph-viewport" id="graph-viewport">
            <div class="graph-canvas" id="graph-canvas">
              <svg class="graph-links" id="task-links"></svg>
            </div>
          </div>
        </div>
      </section>

      <div class="detail-panel">
        <section class="panel detail-card" id="task-detail"></section>
        <section class="panel detail-card">
          <h3>Recent Events</h3>
          <div class="timeline" id="timeline"></div>
        </section>
        <section class="panel detail-card">
          <h3>Feedback Queues</h3>
          <div class="feedback-list" id="feedback-list"></div>
        </section>
      </div>
    </div>

    <section class="panel detail-card">
      <h3>Warnings and Notes</h3>
      <div class="warnings" id="warnings"></div>
    </section>

    <section class="panel detail-card">
      <details class="debug">
        <summary>Raw Matrix JSON</summary>
        <pre class="raw-json" id="raw-json"></pre>
      </details>
    </section>
  </div>

  <script id="matrix-data" type="application/json">__PAYLOAD__</script>
  <script>
    const payload = JSON.parse(document.getElementById("matrix-data").textContent);
    const viewport = document.getElementById("graph-viewport");
    const canvas = document.getElementById("graph-canvas");
    const linksSvg = document.getElementById("task-links");
    const zoomOutButton = document.getElementById("zoom-out");
    const zoomInButton = document.getElementById("zoom-in");
    const zoomFitButton = document.getElementById("zoom-fit");
    const zoomLabel = document.getElementById("zoom-label");
    const autoRefreshToggleButton = document.getElementById("auto-refresh-toggle");
    const autoRefreshLabel = document.getElementById("auto-refresh-label");
    const refreshViewButton = document.getElementById("refresh-view");
    const resetLayoutButton = document.getElementById("reset-layout");
    const detail = document.getElementById("task-detail");
    const timeline = document.getElementById("timeline");
    const feedbackList = document.getElementById("feedback-list");
    const overviewCards = document.getElementById("overview-cards");
    const warnings = document.getElementById("warnings");
    const rawJson = document.getElementById("raw-json");
    const legend = document.getElementById("board-legend");

    const tasks = payload.tasks || [];
    const taskMap = new Map(tasks.map(task => [task.id, task]));
    const selected = { taskId: payload.summary.primary_task_id || (tasks[0] && tasks[0].id) || null };
    const layoutStorageKey = `humanize:scenario-matrix-layout:v2:${payload.meta.session_dir || payload.meta.source_file}`;
    const autoRefreshStorageKey = `${layoutStorageKey}:auto-refresh`;
    const graphMetrics = {
      canvasPaddingX: 64,
      canvasPaddingY: 122,
      stageGap: 96,
      stageInsetX: 28,
      stageInsetY: 112,
      nodeWidth: 340,
      subcolumnGap: 34,
      maxRowsPerSubcolumn: 4,
      nodeGapY: 34
    };
    const layoutState = { positions: {} };
    const dragState = { taskId: null, pointerId: null, startX: 0, startY: 0, originX: 0, originY: 0, moved: false };
    const panState = { active: false, pointerId: null, startX: 0, startY: 0, cameraX: 0, cameraY: 0 };
    const cameraState = { x: 28, y: 28, scale: 0.9, minScale: 0.45, maxScale: 1.8 };
    const autoRefreshState = { enabled: true, intervalSec: 60, remainingSec: 60, timerId: null };
    let linkFrame = 0;

    const bucketConfig = [
      { id: "primary", title: "Primary Objective", subtitle: "Exactly one manager-owned current objective." },
      { id: "supporting", title: "Supporting Window", subtitle: "Bounded helpers around the active checkpoint." },
      { id: "active", title: "Active Backlog", subtitle: "Ready, blocked, or queued tasks outside the current window." },
      { id: "done", title: "Completed", subtitle: "Finished tasks kept for dependency context." },
      { id: "deferred", title: "Deferred / Watchlist", subtitle: "Explicitly held back until the manager promotes them." }
    ];
    const bucketPriority = { primary: 0, supporting: 1, active: 2, done: 3, deferred: 4 };
    const statePriority = { in_progress: 0, ready: 1, pending: 2, blocked: 3, needs_replan: 4, done: 5, deferred: 6 };

    function el(tag, className, text) {
      const node = document.createElement(tag);
      if (className) node.className = className;
      if (text !== undefined && text !== null) node.textContent = text;
      return node;
    }

    function badge(text, extraClass = "") {
      const node = el("span", `badge ${extraClass}`.trim(), text);
      return node;
    }

    function formatList(items) {
      return Array.isArray(items) && items.length ? items.join(", ") : "none";
    }

    function formatValue(value) {
      if (value === null || value === undefined || value === "") return "n/a";
      if (Array.isArray(value)) return value.length ? value.join(", ") : "n/a";
      if (typeof value === "boolean") return value ? "true" : "false";
      return String(value);
    }

    function renderOverview() {
      const summary = payload.summary || {};
      const convergence = payload.convergence || {};
      const oversight = payload.oversight || {};
      const checkpoint = payload.checkpoint || {};
      const lastReview = payload.last_review || {};
      const cards = [
        {
          label: "Round + Mode",
          title: `Round ${formatValue(summary.current_round)}`,
          body: `${formatValue(summary.mode)} / ${formatValue(summary.projection_mode)}`
        },
        {
          label: "Primary Objective",
          title: summary.primary_task_id ? `${summary.primary_task_id}` : "none",
          body: summary.primary_task_title || "No active primary task"
        },
        {
          label: "Checkpoint",
          title: formatValue(checkpoint.current_id),
          body: `${checkpoint.frontier_changed ? "frontier changed" : "frontier stable"} • ${formatValue(checkpoint.frontier_reason)}`
        },
        {
          label: "Convergence",
          title: formatValue(convergence.status),
          body: `risk ${formatValue(convergence.residual_risk_score)} • next ${formatValue(convergence.next_action)}`
        },
        {
          label: "Oversight",
          title: formatValue(oversight.status),
          body: oversight.intervention ? `${formatValue(oversight.intervention.action)} • ${formatValue(oversight.intervention.reason)}` : `last action ${formatValue(oversight.last_action)}`
        },
        {
          label: "Review + Signals",
          title: `${formatValue(lastReview.phase)} / ${formatValue(lastReview.verdict)}`,
          body: `${formatValue(summary.event_count)} events • ${formatValue(summary.execution_feedback_count)} exec fb • ${formatValue(summary.review_feedback_count)} review fb`
        }
      ];

      cards.forEach(card => {
        const node = el("article", "meta-card");
        node.appendChild(el("small", "", card.label));
        node.appendChild(el("strong", "", card.title));
        node.appendChild(el("span", "", card.body));
        overviewCards.appendChild(node);
      });
    }

    function createTaskCard(task) {
      const node = el("article", `task-card task-node state-${task.state}`);
      node.dataset.taskId = task.id;
      node.appendChild(el("div", "task-id mono", task.id));
      node.appendChild(el("h4", "task-title", task.title));

      const badges = el("div", "badges");
      badges.appendChild(badge(task.state, `state-${task.state}`));
      badges.appendChild(badge(task.routing));
      badges.appendChild(badge(task.kind));
      if (task.is_primary) badges.appendChild(badge("primary", "primary"));
      if (task.is_supporting) badges.appendChild(badge("supporting", "supporting"));
      if (task.risk_bucket === "high") badges.appendChild(badge("risk:high", "risk-high"));
      if (task.wave_label) badges.appendChild(badge(task.wave_label));
      node.appendChild(badges);

      const mini = el("div", "mini-meta");
      mini.appendChild(badge(`lane:${task.lane}`));
      mini.appendChild(badge(`deps:${task.depends_on.length}`));
      mini.appendChild(badge(`dependents:${task.dependent_ids.length}`));
      if (task.target_ac.length) mini.appendChild(badge(task.target_ac.join("/")));
      node.appendChild(mini);

      const foot = el("div", "task-foot");
      foot.textContent = task.scope && task.scope.summary ? task.scope.summary : "No scope summary captured.";
      node.appendChild(foot);

      node.addEventListener("pointerdown", event => beginTaskDrag(event, task.id, node));
      node.addEventListener("pointermove", updateTaskDrag);
      node.addEventListener("pointerup", endTaskDrag);
      node.addEventListener("pointercancel", endTaskDrag);

      return node;
    }

    function estimateTaskHeight(task) {
      const titleLines = Math.max(1, Math.ceil((task.title || "").length / 24));
      const summary = (task.scope && task.scope.summary) || "";
      const summaryLines = Math.max(1, Math.ceil(summary.length / 44));
      const acWeight = Array.isArray(task.target_ac) ? Math.max(0, task.target_ac.length - 1) * 10 : 0;
      return 168 + (titleLines * 19) + (summaryLines * 15) + acWeight;
    }

    function clampPosition(point) {
      return {
        x: Math.max(18, Number(point && point.x) || 0),
        y: Math.max(68, Number(point && point.y) || 0)
      };
    }

    function summarizeBuckets(taskList) {
      const counts = { primary: 0, supporting: 0, active: 0, done: 0, deferred: 0 };
      taskList.forEach(task => {
        const bucket = counts[task.bucket] !== undefined ? task.bucket : "active";
        counts[bucket] += 1;
      });
      return counts;
    }

    function computeDependencyDepth(taskId, memo, visiting) {
      if (memo[taskId] !== undefined) return memo[taskId];
      if (visiting.has(taskId)) return 0;
      visiting.add(taskId);
      const task = taskMap.get(taskId);
      if (!task) {
        visiting.delete(taskId);
        memo[taskId] = 0;
        return 0;
      }

      let depth = 0;
      (task.depends_on || []).forEach(depId => {
        if (!taskMap.has(depId)) return;
        depth = Math.max(depth, computeDependencyDepth(depId, memo, visiting) + 1);
      });
      visiting.delete(taskId);
      memo[taskId] = depth;
      return depth;
    }

    function stageTasks() {
      const depthMemo = {};
      tasks.forEach(task => computeDependencyDepth(task.id, depthMemo, new Set()));
      const grouped = new Map();
      tasks.forEach(task => {
        const stageIndex = depthMemo[task.id] || 0;
        if (!grouped.has(stageIndex)) grouped.set(stageIndex, []);
        grouped.get(stageIndex).push(task);
      });

      const sortedStages = Array.from(grouped.keys()).sort((a, b) => a - b);
      let cursorLeft = graphMetrics.canvasPaddingX;
      return sortedStages.map((stageIndex) => {
        const stageTasks = grouped.get(stageIndex).slice().sort((left, right) => {
          return (
            (bucketPriority[left.bucket] ?? 9) - (bucketPriority[right.bucket] ?? 9) ||
            (statePriority[left.state] ?? 9) - (statePriority[right.state] ?? 9) ||
            left.id.localeCompare(right.id)
          );
        });

        const subcolumnCount = Math.max(1, Math.ceil(stageTasks.length / graphMetrics.maxRowsPerSubcolumn));
        const width = (subcolumnCount * graphMetrics.nodeWidth) + ((subcolumnCount - 1) * graphMetrics.subcolumnGap) + (graphMetrics.stageInsetX * 2);
        const counts = summarizeBuckets(stageTasks);
        const stage = {
          id: `stage-${stageIndex}`,
          index: stageIndex,
          title: `Workflow Stage ${stageIndex}`,
          subtitle: stageIndex === 0 ? "Seed tasks and upstream anchors with no in-graph prerequisites." : `Tasks unlocked after ${stageIndex} dependency hop${stageIndex === 1 ? "" : "s"}.`,
          left: cursorLeft,
          width,
          tasks: stageTasks,
          counts,
          subcolumnCount
        };
        cursorLeft += width + graphMetrics.stageGap;
        return stage;
      });
    }

    function buildDefaultLayout() {
      const positions = {};
      stageTasks().forEach(stage => {
        stage.tasks.forEach((task, index) => {
          const subcolumn = Math.floor(index / graphMetrics.maxRowsPerSubcolumn);
          const row = index % graphMetrics.maxRowsPerSubcolumn;
          const bucketOffset = task.bucket === "primary" ? -10 : (task.bucket === "supporting" ? 0 : (task.bucket === "done" ? 8 : 14));
          positions[task.id] = {
            x: stage.left + graphMetrics.stageInsetX + (subcolumn * (graphMetrics.nodeWidth + graphMetrics.subcolumnGap)),
            y: graphMetrics.stageInsetY + (row * (estimateTaskHeight(task) + graphMetrics.nodeGapY)) + bucketOffset
          };
        });
      });
      return positions;
    }

    function loadStoredLayout() {
      try {
        const raw = window.localStorage.getItem(layoutStorageKey);
        if (!raw) return null;
        const parsed = JSON.parse(raw);
        if (!parsed || typeof parsed !== "object") return null;
        const positions = {};
        tasks.forEach(task => {
          const entry = parsed[task.id];
          if (entry && Number.isFinite(Number(entry.x)) && Number.isFinite(Number(entry.y))) {
            positions[task.id] = clampPosition(entry);
          }
        });
        return Object.keys(positions).length ? positions : null;
      } catch (error) {
        return null;
      }
    }

    function persistLayout() {
      try {
        window.localStorage.setItem(layoutStorageKey, JSON.stringify(layoutState.positions));
      } catch (error) {
      }
    }

    function initializeLayout(forceReset = false) {
      if (forceReset) {
        try {
          window.localStorage.removeItem(layoutStorageKey);
        } catch (error) {
        }
      }
      const defaults = buildDefaultLayout();
      const stored = forceReset ? null : loadStoredLayout();
      layoutState.positions = {};
      tasks.forEach(task => {
        layoutState.positions[task.id] = clampPosition((stored && stored[task.id]) || defaults[task.id] || { x: 40, y: 80 });
      });
    }

    function createStageNode(stage) {
      const node = el("section", "workflow-stage");
      node.dataset.stageId = stage.id;
      node.style.left = `${stage.left}px`;
      node.style.width = `${stage.width}px`;
      const header = el("div", "workflow-stage-header");
      header.appendChild(el("div", "stage-label", `stage ${stage.index} • ${stage.tasks.length} task${stage.tasks.length === 1 ? "" : "s"}`));
      header.appendChild(el("div", "stage-title", stage.title));
      header.appendChild(el("div", "stage-subtitle", stage.subtitle));
      const meta = el("div", "stage-meta");
      if (stage.counts.primary) meta.appendChild(badge(`${stage.counts.primary} primary`, "primary"));
      if (stage.counts.supporting) meta.appendChild(badge(`${stage.counts.supporting} supporting`, "supporting"));
      if (stage.counts.active) meta.appendChild(badge(`${stage.counts.active} active`));
      if (stage.counts.done) meta.appendChild(badge(`${stage.counts.done} done`, "state-done"));
      if (stage.counts.deferred) meta.appendChild(badge(`${stage.counts.deferred} deferred`));
      header.appendChild(meta);
      node.appendChild(header);
      return node;
    }

    function applyNodePosition(node, point) {
      const next = clampPosition(point);
      node.style.left = `${next.x}px`;
      node.style.top = `${next.y}px`;
    }

    function ensureCanvasFitsNode(node) {
      const requiredWidth = node.offsetLeft + node.offsetWidth + graphMetrics.canvasPaddingX;
      const requiredHeight = node.offsetTop + node.offsetHeight + graphMetrics.canvasPaddingY;
      let changed = false;
      if (requiredWidth > canvas.offsetWidth) {
        canvas.style.width = `${Math.ceil(requiredWidth)}px`;
        changed = true;
      }
      if (requiredHeight > canvas.offsetHeight) {
        canvas.style.height = `${Math.ceil(requiredHeight)}px`;
        changed = true;
      }
      if (changed) {
        linksSvg.setAttribute("width", String(canvas.offsetWidth));
        linksSvg.setAttribute("height", String(canvas.offsetHeight));
        linksSvg.setAttribute("viewBox", `0 0 ${canvas.offsetWidth} ${canvas.offsetHeight}`);
      }
    }

    function scheduleDrawLinks() {
      if (linkFrame) return;
      linkFrame = window.requestAnimationFrame(() => {
        linkFrame = 0;
        drawLinks();
      });
    }

    function clampScale(nextScale) {
      return Math.max(cameraState.minScale, Math.min(cameraState.maxScale, nextScale));
    }

    function persistAutoRefreshPreference() {
      try {
        window.localStorage.setItem(autoRefreshStorageKey, autoRefreshState.enabled ? "on" : "off");
      } catch (error) {
      }
    }

    function updateAutoRefreshUI() {
      if (autoRefreshToggleButton) {
        autoRefreshToggleButton.textContent = `Auto Refresh: ${autoRefreshState.enabled ? "On" : "Off"}`;
      }
      if (autoRefreshLabel) {
        autoRefreshLabel.textContent = autoRefreshState.enabled ? `${autoRefreshState.remainingSec}s` : "paused";
      }
    }

    function loadAutoRefreshPreference() {
      try {
        const raw = window.localStorage.getItem(autoRefreshStorageKey);
        if (raw === "off") {
          autoRefreshState.enabled = false;
        } else if (raw === "on") {
          autoRefreshState.enabled = true;
        }
      } catch (error) {
      }
      autoRefreshState.remainingSec = autoRefreshState.intervalSec;
      updateAutoRefreshUI();
    }

    function restartAutoRefreshCountdown() {
      autoRefreshState.remainingSec = autoRefreshState.intervalSec;
      updateAutoRefreshUI();
    }

    function startAutoRefreshTimer() {
      if (autoRefreshState.timerId) {
        window.clearInterval(autoRefreshState.timerId);
      }
      autoRefreshState.timerId = window.setInterval(() => {
        if (!autoRefreshState.enabled) {
          updateAutoRefreshUI();
          return;
        }
        if (dragState.taskId || panState.active) {
          restartAutoRefreshCountdown();
          return;
        }
        if (document.hidden) {
          updateAutoRefreshUI();
          return;
        }
        autoRefreshState.remainingSec -= 1;
        if (autoRefreshState.remainingSec <= 0) {
          window.location.reload();
          return;
        }
        updateAutoRefreshUI();
      }, 1000);
    }

    function toggleAutoRefresh() {
      autoRefreshState.enabled = !autoRefreshState.enabled;
      if (autoRefreshState.enabled) {
        restartAutoRefreshCountdown();
      } else {
        updateAutoRefreshUI();
      }
      persistAutoRefreshPreference();
    }

    function applyCamera() {
      canvas.style.transform = `translate(${cameraState.x}px, ${cameraState.y}px) scale(${cameraState.scale})`;
      if (zoomLabel) {
        zoomLabel.textContent = `${Math.round(cameraState.scale * 100)}%`;
      }
    }

    function setZoom(nextScale, anchorX, anchorY) {
      const clamped = clampScale(nextScale);
      const targetX = Number.isFinite(anchorX) ? anchorX : (viewport.clientWidth / 2);
      const targetY = Number.isFinite(anchorY) ? anchorY : (viewport.clientHeight / 2);
      const worldX = (targetX - cameraState.x) / cameraState.scale;
      const worldY = (targetY - cameraState.y) / cameraState.scale;
      cameraState.scale = clamped;
      cameraState.x = targetX - (worldX * cameraState.scale);
      cameraState.y = targetY - (worldY * cameraState.scale);
      applyCamera();
    }

    function fitGraphToViewport() {
      const stageWidth = Math.max(canvas.offsetWidth + (graphMetrics.canvasPaddingX * 0.5), 1);
      const stageHeight = Math.max(canvas.offsetHeight + (graphMetrics.canvasPaddingY * 0.4), 1);
      const scaleX = (viewport.clientWidth - 48) / stageWidth;
      const scaleY = (viewport.clientHeight - 48) / stageHeight;
      cameraState.scale = clampScale(Math.min(scaleX, scaleY, 1));
      cameraState.x = Math.max(24, (viewport.clientWidth - (canvas.offsetWidth * cameraState.scale)) / 2);
      cameraState.y = Math.max(24, (viewport.clientHeight - (canvas.offsetHeight * cameraState.scale)) / 2);
      applyCamera();
    }

    function syncCanvasGeometry() {
      const stages = stageTasks();
      const minWidth = stages.length ? stages[stages.length - 1].left + stages[stages.length - 1].width + graphMetrics.canvasPaddingX : 1280;
      let width = minWidth;
      let height = 980;
      canvas.querySelectorAll(".task-node").forEach(node => {
        width = Math.max(width, node.offsetLeft + node.offsetWidth + graphMetrics.canvasPaddingX);
        height = Math.max(height, node.offsetTop + node.offsetHeight + graphMetrics.canvasPaddingY);
      });
      canvas.style.width = `${Math.ceil(width)}px`;
      canvas.style.height = `${Math.ceil(height)}px`;
      linksSvg.setAttribute("width", String(Math.ceil(width)));
      linksSvg.setAttribute("height", String(Math.ceil(height)));
      linksSvg.setAttribute("viewBox", `0 0 ${Math.ceil(width)} ${Math.ceil(height)}`);
      applyCamera();
      scheduleDrawLinks();
    }

    function centerTask(taskId, anchorFractionX = 0.36, anchorFractionY = 0.38) {
      const node = taskId ? canvas.querySelector(`[data-task-id="${CSS.escape(taskId)}"]`) : null;
      if (!node) return;
      const anchorX = viewport.clientWidth * anchorFractionX;
      const anchorY = viewport.clientHeight * anchorFractionY;
      cameraState.x = anchorX - ((node.offsetLeft + (node.offsetWidth / 2)) * cameraState.scale);
      cameraState.y = anchorY - ((node.offsetTop + (node.offsetHeight / 2)) * cameraState.scale);
      applyCamera();
    }

    function beginTaskDrag(event, taskId, node) {
      if (event.button !== 0) return;
      const origin = layoutState.positions[taskId];
      if (!origin) return;
      dragState.taskId = taskId;
      dragState.pointerId = event.pointerId;
      dragState.startX = event.clientX;
      dragState.startY = event.clientY;
      dragState.originX = origin.x;
      dragState.originY = origin.y;
      dragState.moved = false;
      selected.taskId = taskId;
      renderSelection();
      node.classList.add("dragging");
      if (typeof node.setPointerCapture === "function") {
        node.setPointerCapture(event.pointerId);
      }
      event.preventDefault();
      event.stopPropagation();
    }

    function updateTaskDrag(event) {
      if (!dragState.taskId || event.pointerId !== dragState.pointerId) return;
      const node = canvas.querySelector(`[data-task-id="${CSS.escape(dragState.taskId)}"]`);
      if (!node) return;
      const next = clampPosition({
        x: dragState.originX + ((event.clientX - dragState.startX) / cameraState.scale),
        y: dragState.originY + ((event.clientY - dragState.startY) / cameraState.scale)
      });
      dragState.moved = dragState.moved || Math.abs(next.x - dragState.originX) > 4 || Math.abs(next.y - dragState.originY) > 4;
      layoutState.positions[dragState.taskId] = next;
      applyNodePosition(node, next);
      ensureCanvasFitsNode(node);
      scheduleDrawLinks();
    }

    function endTaskDrag(event) {
      if (!dragState.taskId) return;
      if (event && dragState.pointerId !== null && event.pointerId !== dragState.pointerId) return;
      const node = canvas.querySelector(`[data-task-id="${CSS.escape(dragState.taskId)}"]`);
      if (node) {
        node.classList.remove("dragging");
        if (typeof node.releasePointerCapture === "function" && dragState.pointerId !== null) {
          try {
            node.releasePointerCapture(dragState.pointerId);
          } catch (error) {
          }
        }
      }
      persistLayout();
      dragState.taskId = null;
      dragState.pointerId = null;
      dragState.moved = false;
      syncCanvasGeometry();
    }

    function beginPan(event) {
      if (event.button !== 0) return;
      if (event.target.closest(".task-node")) return;
      panState.active = true;
      panState.pointerId = event.pointerId;
      panState.startX = event.clientX;
      panState.startY = event.clientY;
      panState.cameraX = cameraState.x;
      panState.cameraY = cameraState.y;
      viewport.classList.add("is-panning");
      if (typeof viewport.setPointerCapture === "function") {
        viewport.setPointerCapture(event.pointerId);
      }
      event.preventDefault();
    }

    function updatePan(event) {
      if (!panState.active || event.pointerId !== panState.pointerId) return;
      cameraState.x = panState.cameraX + (event.clientX - panState.startX);
      cameraState.y = panState.cameraY + (event.clientY - panState.startY);
      applyCamera();
    }

    function endPan(event) {
      if (!panState.active) return;
      if (event && panState.pointerId !== null && event.pointerId !== panState.pointerId) return;
      if (typeof viewport.releasePointerCapture === "function" && panState.pointerId !== null) {
        try {
          viewport.releasePointerCapture(panState.pointerId);
        } catch (error) {
        }
      }
      panState.active = false;
      panState.pointerId = null;
      viewport.classList.remove("is-panning");
    }

    function renderGraph() {
      const stages = stageTasks();
      canvas.innerHTML = "";
      stages.forEach(stage => {
        canvas.appendChild(createStageNode(stage));
      });
      canvas.appendChild(linksSvg);
      tasks.forEach(task => {
        const node = createTaskCard(task);
        applyNodePosition(node, layoutState.positions[task.id]);
        canvas.appendChild(node);
      });

      const counts = payload.summary.state_counts || {};
      legend.textContent = `workflow stages flow left → right by dependency depth • drag cards to refine local branches • states: ready ${counts.ready || 0} • in_progress ${counts.in_progress || 0} • blocked ${counts.blocked || 0} • needs_replan ${counts.needs_replan || 0}`;

      window.requestAnimationFrame(() => {
        syncCanvasGeometry();
        renderSelection();
      });
    }

    function renderSelection() {
      const task = taskMap.get(selected.taskId) || tasks[0] || null;
      document.querySelectorAll(".task-card").forEach(card => {
        card.classList.toggle("active", card.dataset.taskId === (task && task.id));
      });
      detail.innerHTML = "";
      if (!task) {
        detail.appendChild(el("h3", "", "No task selected"));
        detail.appendChild(el("p", "muted", "This matrix snapshot does not contain any tasks."));
        feedbackList.innerHTML = "";
        return;
      }

      detail.appendChild(el("h3", "", `${task.id} — ${task.title}`));
      detail.appendChild(el("p", "muted", task.scope && task.scope.summary ? task.scope.summary : "No scope summary captured for this task."));

      const grid = el("div", "detail-grid");
      const stats = [
        ["State", task.state],
        ["Lane / Routing", `${task.lane} / ${task.routing}`],
        ["Bucket", task.bucket],
        ["Risk", task.risk_bucket],
        ["Depends On", formatList(task.depends_on)],
        ["Dependents", formatList(task.dependent_ids)],
        ["Target AC", formatList(task.target_ac)],
        ["Wave", task.wave_label || "none"],
        ["Attempts", task.strategy.attempt_count],
        ["Repeated Failures", task.strategy.repeated_failure_count],
        ["Method Switch", task.strategy.method_switch_required],
        ["Stuck Score", task.health.stuck_score]
      ];
      stats.forEach(([label, value]) => {
        const item = el("div", "detail-stat");
        item.appendChild(el("small", "", label));
        item.appendChild(el("strong", "", formatValue(value)));
        grid.appendChild(item);
      });
      detail.appendChild(grid);

      const sections = [
        ["Paths", task.scope && task.scope.paths],
        ["Constraints", task.scope && task.scope.constraints],
        ["Assumptions", task.assumptions]
      ];
      sections.forEach(([label, items]) => {
        const wrapper = el("div", "list");
        wrapper.appendChild(el("strong", "", label));
        const values = Array.isArray(items) && items.length ? items : ["none"];
        values.forEach(value => wrapper.appendChild(el("div", "list-item", value)));
        detail.appendChild(wrapper);
      });

      feedbackList.innerHTML = "";
      const relatedFeedback = task.feedback || [];
      if (relatedFeedback.length === 0) {
        feedbackList.appendChild(el("div", "feedback-item", "No feedback queued for the selected task."));
      } else {
        relatedFeedback.forEach(entry => {
          const node = el("div", "feedback-item");
          node.appendChild(el("strong", "", `${formatValue(entry.source)} / ${formatValue(entry.kind)}`));
          node.appendChild(el("div", "muted", `from ${formatValue(entry.suggested_by)} • ${formatValue(entry.created_at)}`));
          node.appendChild(el("div", "", formatValue(entry.summary)));
          feedbackList.appendChild(node);
        });
      }
    }

    function renderTimeline() {
      const events = payload.events || [];
      if (events.length === 0) {
        timeline.appendChild(el("div", "timeline-item", "No events recorded in this snapshot."));
        return;
      }
      events.slice(0, 16).forEach(event => {
        const node = el("div", "timeline-item");
        const top = [event.type, event.task_id, event.verdict].filter(Boolean).join(" • ");
        node.appendChild(el("strong", "", top || "event"));
        node.appendChild(el("div", "muted", `round ${formatValue(event.round)} • ${formatValue(event.phase)} • ${formatValue(event.created_at)}`));
        if (event.summary) {
          node.appendChild(el("div", "", formatValue(event.summary)));
        }
        timeline.appendChild(node);
      });
    }

    function renderWarnings() {
      const warningItems = [];
      const planWarnings = (payload.plan && payload.plan.warnings) || [];
      warningItems.push(...planWarnings);
      if ((payload.hidden_tasks || []).length > 0) {
        const hidden = payload.hidden_tasks;
        const preview = hidden.slice(0, 3).join(" • ");
        warningItems.push(`Viewer hid ${hidden.length} transient or malformed task node${hidden.length === 1 ? "" : "s"} from the graph: ${preview}${hidden.length > 3 ? " • …" : ""}`);
      }
      if ((payload.oversight || {}).intervention) {
        warningItems.push(`Oversight is active: ${formatValue(payload.oversight.intervention.action)} — ${formatValue(payload.oversight.intervention.message)}`);
      }
      warningItems.push(`Schema v${formatValue(payload.meta.schema_version)} • task breakdown status ${formatValue((payload.plan || {}).task_breakdown_status)}`);

      warningItems.forEach(item => warnings.appendChild(el("div", "list-item", item)));
    }

    function drawLinks() {
      const width = Math.max(1, Math.ceil(canvas.offsetWidth));
      const height = Math.max(1, Math.ceil(canvas.offsetHeight));
      linksSvg.style.width = `${width}px`;
      linksSvg.style.height = `${height}px`;
      linksSvg.setAttribute("width", String(width));
      linksSvg.setAttribute("height", String(height));
      linksSvg.setAttribute("viewBox", `0 0 ${width} ${height}`);
      linksSvg.innerHTML = '<defs><marker id="arrow" markerWidth="10" markerHeight="10" refX="9" refY="3" orient="auto"><path d="M0,0 L10,3 L0,6 Z" fill="rgba(32,50,63,0.30)"></path></marker></defs>';

      tasks.forEach(task => {
        const toEl = canvas.querySelector(`[data-task-id="${CSS.escape(task.id)}"]`);
        if (!toEl) return;
        const toX = toEl.offsetLeft;
        const toY = toEl.offsetTop + (toEl.offsetHeight / 2);
        (task.depends_on || []).forEach(depId => {
          const fromEl = canvas.querySelector(`[data-task-id="${CSS.escape(depId)}"]`);
          if (!fromEl) return;
          const dependency = taskMap.get(depId);
          const fromX = fromEl.offsetLeft + fromEl.offsetWidth;
          const fromY = fromEl.offsetTop + (fromEl.offsetHeight / 2);
          let stroke = "rgba(32,50,63,0.28)";
          if (task.state === "blocked" || task.state === "needs_replan" || (dependency && (dependency.state === "blocked" || dependency.state === "needs_replan"))) {
            stroke = "rgba(190,106,15,0.52)";
          } else if (task.is_primary || (dependency && dependency.is_primary)) {
            stroke = "rgba(15,109,106,0.44)";
          } else if (task.is_supporting || (dependency && dependency.is_supporting)) {
            stroke = "rgba(195,108,47,0.42)";
          }
          const bendX = fromX + ((toX - fromX) / 2);
          const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
          path.setAttribute("d", `M ${fromX} ${fromY} L ${bendX} ${fromY} L ${bendX} ${toY} L ${toX} ${toY}`);
          path.setAttribute("fill", "none");
          path.setAttribute("stroke", stroke);
          path.setAttribute("stroke-width", task.is_primary || (dependency && dependency.is_primary) ? "2.6" : "2.1");
          path.setAttribute("stroke-linecap", "round");
          path.setAttribute("stroke-linejoin", "round");
          path.setAttribute("marker-end", "url(#arrow)");
          linksSvg.appendChild(path);
        });
      });
    }

    renderOverview();
    initializeLayout();
    loadAutoRefreshPreference();
    renderGraph();
    renderTimeline();
    renderWarnings();
    rawJson.textContent = JSON.stringify(payload.raw_matrix, null, 2);
    if (zoomOutButton) {
      zoomOutButton.addEventListener("click", () => setZoom(cameraState.scale / 1.15));
    }
    if (zoomInButton) {
      zoomInButton.addEventListener("click", () => setZoom(cameraState.scale * 1.15));
    }
    if (zoomFitButton) {
      zoomFitButton.addEventListener("click", () => fitGraphToViewport());
    }
    if (autoRefreshToggleButton) {
      autoRefreshToggleButton.addEventListener("click", () => toggleAutoRefresh());
    }
    if (refreshViewButton) {
      refreshViewButton.addEventListener("click", () => {
        restartAutoRefreshCountdown();
        window.location.reload();
      });
    }
    if (resetLayoutButton) {
      resetLayoutButton.addEventListener("click", () => {
        initializeLayout(true);
        restartAutoRefreshCountdown();
        renderGraph();
        window.requestAnimationFrame(() => {
          fitGraphToViewport();
          centerTask(selected.taskId || payload.summary.primary_task_id);
        });
      });
    }
    viewport.addEventListener("pointerdown", beginPan);
    viewport.addEventListener("pointermove", updatePan);
    viewport.addEventListener("pointerup", endPan);
    viewport.addEventListener("pointercancel", endPan);
    viewport.addEventListener("wheel", event => {
      if (event.ctrlKey || event.metaKey) {
        event.preventDefault();
        const factor = event.deltaY < 0 ? 1.1 : (1 / 1.1);
        const rect = viewport.getBoundingClientRect();
        setZoom(cameraState.scale * factor, event.clientX - rect.left, event.clientY - rect.top);
        return;
      }
      if (event.deltaX === 0 && event.deltaY === 0) return;
      event.preventDefault();
      cameraState.x -= event.deltaX;
      cameraState.y -= event.deltaY;
      applyCamera();
    }, { passive: false });
    window.addEventListener("resize", () => {
      syncCanvasGeometry();
      fitGraphToViewport();
      centerTask(selected.taskId || payload.summary.primary_task_id);
    });
    if (typeof ResizeObserver !== "undefined") {
      const observer = new ResizeObserver(() => scheduleDrawLinks());
      observer.observe(canvas);
      observer.observe(viewport);
    }
    startAutoRefreshTimer();
    window.requestAnimationFrame(() => {
      fitGraphToViewport();
      centerTask(selected.taskId || payload.summary.primary_task_id);
    });
  </script>
</body>
</html>
"""
    return (
        template.replace("__TITLE__", html_title)
        .replace("__SOURCE_FILE__", source_file)
        .replace("__GENERATED_AT__", generated_at)
        .replace("__SESSION_DIR__", session_dir)
        .replace("__PAYLOAD__", payload)
    )


def serve_dashboard(input_arg: str | None, page_title: str, bind: str, port: int, once: bool) -> int:
    class ScenarioMatrixHandler(BaseHTTPRequestHandler):
        server_version = "ScenarioMatrixViewer/1.0"

        def log_message(self, format: str, *args: Any) -> None:
            return

        def _send_text(self, status: HTTPStatus, body: str, content_type: str) -> None:
            encoded = body.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", f"{content_type}; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(encoded)

        def _maybe_shutdown(self) -> None:
            if once:
                Thread(target=self.server.shutdown, daemon=True).start()

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path == "/healthz":
                self._send_text(HTTPStatus.OK, "ok\n", "text/plain")
                return

            if parsed.path not in ("/", "/index.html"):
                self._send_text(HTTPStatus.NOT_FOUND, "Not found\n", "text/plain")
                return

            try:
                view_model, _, _ = load_view_model_from_input(input_arg)
                html = render_html(view_model, page_title)
                self._send_text(HTTPStatus.OK, html, "text/html")
            except (FileNotFoundError, ValueError) as exc:
                message = escape(str(exc))
                body = (
                    "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\" />"
                    f"<title>{escape(page_title)} — Error</title></head><body>"
                    f"<h1>{escape(page_title)}</h1><p>Unable to load the current scenario matrix snapshot.</p>"
                    f"<pre>{message}</pre></body></html>"
                )
                self._send_text(HTTPStatus.INTERNAL_SERVER_ERROR, body, "text/html")
            self._maybe_shutdown()

    class ScenarioMatrixServer(ThreadingHTTPServer):
        allow_reuse_address = True
        daemon_threads = True

    try:
        server = ScenarioMatrixServer((bind, port), ScenarioMatrixHandler)
    except OSError as exc:
        raise OSError(f"unable to start scenario matrix client on {bind}:{port}: {exc}") from exc

    host, actual_port = server.server_address[:2]
    display_host = "127.0.0.1" if host in ("0.0.0.0", "", "::") else str(host)
    print(f"http://{display_host}:{actual_port}/", flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Render a Humanize scenario matrix snapshot into a local HTML dashboard."
    )
    parser.add_argument(
        "--input",
        help="Matrix JSON, RLCR session dir, state file, or project dir. Defaults to the latest local RLCR session.",
    )
    parser.add_argument(
        "--output",
        help="HTML output path. Defaults next to the matrix/session as *-view.html.",
    )
    parser.add_argument(
        "--title",
        default="Scenario Matrix Dashboard",
        help="Page title for the generated HTML.",
    )
    parser.add_argument(
        "--serve",
        action="store_true",
        help="Run a local HTML client that re-renders the current matrix snapshot on each page refresh.",
    )
    parser.add_argument(
        "--bind",
        default="127.0.0.1",
        help="Bind address for --serve mode. Default: 127.0.0.1",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=8765,
        help="Port for --serve mode. Use 0 to auto-select an open port. Default: 8765",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Serve a single HTML request and then exit. Useful for tests.",
    )
    args = parser.parse_args(argv)

    if args.serve:
        try:
            return serve_dashboard(args.input, args.title, args.bind, args.port, args.once)
        except OSError as exc:
            return die(str(exc))

    try:
        matrix_file, session_dir = resolve_input(args.input)
        output_file = choose_output_path(matrix_file, session_dir, args.output)
        matrix = load_matrix(matrix_file)
    except (FileNotFoundError, ValueError) as exc:
        return die(str(exc))

    output_file.parent.mkdir(parents=True, exist_ok=True)
    view_model = build_view_model(matrix, matrix_file, session_dir)
    html = render_html(view_model, args.title)
    output_file.write_text(html, encoding="utf-8")
    print(output_file)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
