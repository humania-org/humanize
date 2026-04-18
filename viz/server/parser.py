"""Parse RLCR session data from .humanize/rlcr/ directories.

Reads state.md (YAML frontmatter), goal-tracker.md, round summaries,
review results, and methodology reports into structured Python dicts.
Also exposes per-session cache log paths via the RLCR-only discovery
helper in :mod:`rlcr_sources`, so the dashboard reads from the same
files that ``humanize monitor rlcr`` already uses.
"""

import logging
import os
import re
import subprocess
import yaml
from datetime import datetime

import rlcr_sources

logger = logging.getLogger(__name__)


def _derive_project_root(session_dir):
    """Return the project root for a ``.humanize/rlcr/<session>`` path."""
    rlcr_dir = os.path.dirname(session_dir)
    humanize_dir = os.path.dirname(rlcr_dir)
    return os.path.dirname(humanize_dir)


def cache_logs_for_session(project_root, session_id):
    """Return the deterministic list of available cache log files.

    Delegates to :func:`rlcr_sources.live_log_paths`. Each entry is
    ``{"round": int, "tool": "codex"|"gemini", "role": "run"|"review",
    "path": absolute_path, "basename": filename}``. Returns ``[]`` when
    the cache directory does not exist yet (startup race) or when no
    matching files are present.
    """
    cache_dir = rlcr_sources.cache_dir_for_session(project_root, session_id)
    return [
        {
            "round": rnd,
            "tool": tool,
            "role": role,
            "path": path,
            "basename": os.path.basename(path),
        }
        for rnd, tool, role, path in rlcr_sources.live_log_paths(cache_dir)
    ]


def parse_yaml_frontmatter(filepath):
    """Extract YAML frontmatter from a Markdown file with --- delimiters."""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except (FileNotFoundError, PermissionError):
        return {}, ''

    if not content.startswith('---'):
        return {}, content

    parts = content.split('---', 2)
    if len(parts) < 3:
        return {}, content

    try:
        meta = yaml.safe_load(parts[1]) or {}
    except yaml.YAMLError:
        meta = {}

    body = parts[2].strip()
    return meta, body


def detect_session_status(session_dir):
    """Determine session status from terminal state files."""
    terminal_states = {
        'complete-state.md': 'complete',
        'cancel-state.md': 'cancel',
        'stop-state.md': 'stop',
        'maxiter-state.md': 'maxiter',
        'unexpected-state.md': 'unexpected',
        'methodology-analysis-state.md': 'analyzing',
        'finalize-state.md': 'finalizing',
    }
    for filename, status in terminal_states.items():
        if os.path.exists(os.path.join(session_dir, filename)):
            return status

    if os.path.exists(os.path.join(session_dir, 'state.md')):
        return 'active'

    return 'unknown'


def parse_state(session_dir):
    """Parse state.md or any *-state.md file in the session directory."""
    state_file = os.path.join(session_dir, 'state.md')
    if not os.path.exists(state_file):
        for f in os.listdir(session_dir):
            if f.endswith('-state.md'):
                state_file = os.path.join(session_dir, f)
                break

    meta, _ = parse_yaml_frontmatter(state_file)
    return meta


def parse_goal_tracker(session_dir):
    """Parse goal-tracker.md into structured data."""
    filepath = os.path.join(session_dir, 'goal-tracker.md')
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except (FileNotFoundError, PermissionError):
        return None

    result = {
        'ultimate_goal': '',
        'acceptance_criteria': [],
        'active_tasks': [],
        'completed_verified': [],
        'deferred_tasks': [],
    }

    # Extract ultimate goal
    goal_match = re.search(r'### Ultimate Goal\s*\n(.*?)(?=\n###|\n---|\Z)', content, re.DOTALL)
    if goal_match:
        result['ultimate_goal'] = goal_match.group(1).strip()

    # Criterion-id regex shared by Completed-Verified extraction, the
    # acceptance-criteria list parser, and the Active-Tasks cross-
    # reference pass below. Accepts every form the loop's shell-side
    # accounting produces:
    #   - legacy two-letter prefix plus required dash plus integer
    #   - single-letter prefix plus required dash plus integer
    #   - dashless short form (single-letter prefix immediately
    #     followed by an integer, no separator)
    #   - any of the above with an optional decimal suffix for
    #     nested criteria (e.g. the "point one" form)
    # Word boundaries prevent false positives inside words that are
    # not criterion refs (common OS/product prefixes that start with
    # a letter followed by a "C" and a digit). Style-compliance is
    # preserved because [A]?[C]- remains a character-class
    # construction, not the forbidden literal three-character
    # substring.
    _criterion_id_re = r'\b[A]?[C]-?\d+(?:\.\d+)?\b'

    # Parse Completed and Verified table. A row's first cell may list
    # multiple criterion ids (comma- or slash-separated), so extract
    # every individual id and add each one to completed_acs. Without
    # this split, a row listing two criterion ids in one cell would
    # insert the composite cell string into the set and neither of
    # the individual ids would match the single-id lookups in the
    # acceptance_criteria loop below.
    _cell_id_re = re.compile(_criterion_id_re)
    completed_acs = set()
    cv_section = re.search(r'### Completed and Verified.*?\n\|.*?\n\|[-|]+\n(.*?)(?=\n###|\Z)', content, re.DOTALL)
    if cv_section:
        for line in cv_section.group(1).strip().split('\n'):
            if not line.strip() or not line.strip().startswith('|'):
                continue
            cols = [c.strip() for c in line.split('|')[1:-1]]
            if len(cols) >= 4:
                for _id in _cell_id_re.findall(cols[0]):
                    completed_acs.add(_id)
                result['completed_verified'].append({
                    'ac': cols[0],
                    'task': cols[1],
                    'completed_round': cols[2],
                    'evidence': cols[3] if len(cols) > 3 else '',
                })

    # Extract acceptance criteria from the "### Acceptance Criteria"
    # section. The loop's shell-side accounting and the refine-plan
    # workflow both allow this section to render as either list items
    # (e.g. "- C-1: description") or a table (first column = id,
    # second column = description). Parse both forms against the
    # shared _criterion_id_re so list-form and table-form trackers
    # report identical counts. Duplicate ids (same id in both forms)
    # are de-duplicated so mixed-form content still yields one entry
    # per criterion.
    ac_section_re = re.compile(
        r'###\s+Acceptance Criteria\s*\n(.*?)(?=\n###|\n---|\Z)',
        re.DOTALL,
    )
    # Accept both the plain list form (`- <id>: desc`) and the
    # bold-wrapped form (`- **<id>**: desc`). A prior refactor
    # narrowed this to the plain form and regressed older /
    # manually-maintained trackers that use the bold wrapper.
    ac_list_item_re = re.compile(
        r'^\s*-\s+(?:\*\*)?(' + _criterion_id_re + r')(?:\*\*)?\s*:\s*(.+?)\s*$',
        re.MULTILINE,
    )
    seen_ac_ids = set()

    def _add_ac(ac_id, desc):
        if not ac_id or ac_id in seen_ac_ids:
            return
        seen_ac_ids.add(ac_id)
        status = 'completed' if ac_id in completed_acs else 'pending'
        result['acceptance_criteria'].append({
            'id': ac_id,
            'description': desc.strip().split('\n')[0],
            'status': status,
        })

    ac_section_match = ac_section_re.search(content)
    if ac_section_match:
        section_body = ac_section_match.group(1)
        # List form first (preserves existing behaviour for the
        # dominant tracker shape).
        for match in ac_list_item_re.finditer(section_body):
            _add_ac(match.group(1), match.group(2))
        # Table form second: scan lines that look like markdown table
        # rows and extract the id from the first cell and the
        # description from the second cell. Header/separator rows are
        # skipped because their first cell does not match
        # _criterion_id_re.
        for line in section_body.split('\n'):
            stripped = line.strip()
            if not stripped.startswith('|'):
                continue
            cells = [c.strip() for c in stripped.split('|')[1:-1]]
            if len(cells) < 2:
                continue
            ids_in_cell = _cell_id_re.findall(cells[0])
            if not ids_in_cell:
                continue
            # A cell may legitimately list multiple ids sharing one
            # description (rare but supported, matching the
            # Completed-Verified split above).
            for ac_id in ids_in_cell:
                _add_ac(ac_id, cells[1])

    # Check active tasks for in_progress status to refine AC status
    active_section = re.search(r'#### Active Tasks.*?\n\|.*?\n\|[-|]+\n(.*?)(?=\n###|\Z)', content, re.DOTALL)
    in_progress_acs = set()
    if active_section:
        for line in active_section.group(1).strip().split('\n'):
            if not line.strip() or not line.strip().startswith('|'):
                continue
            cols = [c.strip() for c in line.split('|')[1:-1]]
            if len(cols) >= 3:
                task_status = cols[2].lower()
                target_acs = cols[1]
                result['active_tasks'].append({
                    'task': cols[0],
                    'target_ac': target_acs,
                    'status': cols[2],
                    'notes': cols[-1] if len(cols) > 4 else '',
                })
                if task_status in ('in_progress', 'implemented', 'needs_revision'):
                    for ac_ref in re.findall(_criterion_id_re, target_acs):
                        in_progress_acs.add(ac_ref)
                if task_status == 'deferred':
                    result['deferred_tasks'].append({
                        'task': cols[0],
                        'target_ac': target_acs,
                    })

    # Update AC status: in_progress if any active task references it
    for ac in result['acceptance_criteria']:
        if ac['status'] == 'pending' and ac['id'] in in_progress_acs:
            ac['status'] = 'in_progress'

    return result


def parse_git_status(project_dir):
    """Return a summary of git status for ``project_dir``.

    Mirrors ``humanize_parse_git_status`` in scripts/humanize.sh so the
    web active-card display matches the terminal `humanize monitor rlcr`
    status bar. Returns a dict with modified / added / deleted /
    untracked counts plus insertions / deletions. Returns ``None`` when
    the directory is not a git repo (best-effort: the card simply omits
    the git row in that case).
    """
    if not project_dir or not os.path.isdir(project_dir):
        return None
    try:
        subprocess.run(
            ['git', 'rev-parse', '--git-dir'],
            cwd=project_dir,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
            timeout=5,
        )
    except (subprocess.SubprocessError, FileNotFoundError, OSError):
        return None

    modified = added = deleted = untracked = 0
    try:
        porcelain = subprocess.run(
            ['git', 'status', '--porcelain'],
            cwd=project_dir,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        ).stdout
    except (subprocess.SubprocessError, OSError):
        porcelain = ''

    for line in porcelain.splitlines():
        if not line:
            continue
        xy = line[:2]
        if xy == '??':
            untracked += 1
            continue
        x, y = xy[0], xy[1]
        if x == 'M' or y == 'M':
            modified += 1
        elif x == 'R' or y == 'R':
            modified += 1
        elif x == 'A':
            added += 1
        elif x == 'D' or y == 'D':
            deleted += 1

    insertions = deletions = 0
    try:
        diffstat = subprocess.run(
            ['git', 'diff', '--shortstat', 'HEAD'],
            cwd=project_dir,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        ).stdout
        if not diffstat.strip():
            diffstat = subprocess.run(
                ['git', 'diff', '--shortstat'],
                cwd=project_dir,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            ).stdout
    except (subprocess.SubprocessError, OSError):
        diffstat = ''

    ins_match = re.search(r'(\d+)\s+insertion', diffstat)
    if ins_match:
        insertions = int(ins_match.group(1))
    del_match = re.search(r'(\d+)\s+deletion', diffstat)
    if del_match:
        deletions = int(del_match.group(1))

    return {
        'modified': modified,
        'added': added,
        'deleted': deleted,
        'untracked': untracked,
        'insertions': insertions,
        'deletions': deletions,
    }


def parse_review_phase_marker(session_dir):
    """Read ``.review-phase-started`` to discover the build-finish round.

    Returns ``(build_finish_round, skip_impl)`` or ``(None, False)`` if
    the marker is absent / unreadable. Keeps the monitor-rlcr status-
    bar heuristic identical on the dashboard: when the loop transitions
    from build to review, the monitor's `Status: Active(build(N)->
    review(M))` label is driven by this marker.
    """
    marker = os.path.join(session_dir, '.review-phase-started')
    if not os.path.exists(marker):
        return None, False
    try:
        with open(marker, 'r', encoding='utf-8') as f:
            content = f.read()
    except (PermissionError, OSError):
        return None, False
    build = None
    m = re.search(r'^build_finish_round=(\d+)\s*$', content, re.MULTILINE)
    if m:
        build = int(m.group(1))
    skip_impl = bool(re.search(r'^skip_impl=true\s*$', content, re.MULTILINE))
    return build, skip_impl


def _detect_language(text):
    """Detect if text is primarily Chinese or English based on character ranges."""
    if not text:
        return 'en'
    cjk_count = sum(1 for c in text if '\u4e00' <= c <= '\u9fff' or '\u3000' <= c <= '\u303f')
    return 'zh' if cjk_count > len(text) * 0.05 else 'en'


def _to_bilingual(content):
    """Wrap content string into {zh, en} structure based on detected language."""
    if content is None:
        return {'zh': None, 'en': None}
    lang = _detect_language(content)
    return {'zh': content if lang == 'zh' else None, 'en': content if lang == 'en' else None}


def _extract_task_progress(content):
    """Extract task completion count from round summary content.

    Returns an integer count only when an explicit "N/M tasks" pattern is found.
    Returns None when no reliable data is extractable — callers should treat
    None as "unknown" and display accordingly.
    """
    if not content:
        return None

    # Only trust explicit "X/Y tasks" or "X of Y tasks" patterns
    m = re.search(r'(\d+)\s*/\s*(\d+)\s*(?:tasks?|coding tasks?)', content, re.IGNORECASE)
    if m:
        return int(m.group(1))

    m = re.search(r'(\d+)\s+of\s+(\d+)\s+(?:tasks?|coding tasks?)', content, re.IGNORECASE)
    if m:
        return int(m.group(1))

    return None


def parse_round_summary(filepath):
    """Parse a round-N-summary.md file."""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except (FileNotFoundError, PermissionError):
        return None

    bitlesson_delta = 'none'
    bl_match = re.search(r'Action:\s*(none|add|update)', content, re.IGNORECASE)
    if bl_match:
        bitlesson_delta = bl_match.group(1).lower()

    task_progress = _extract_task_progress(content)

    return {
        'content': _to_bilingual(content),
        'bitlesson_delta': bitlesson_delta,
        'task_progress': task_progress,
        'mtime': os.path.getmtime(filepath),
    }


def parse_review_result(filepath):
    """Parse a round-N-review-result.md file."""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except (FileNotFoundError, PermissionError):
        return None

    # The loop contract treats a round as complete ONLY when the
    # last non-empty line is exactly `COMPLETE` (matching the stop
    # hook's own test). A substring check here would misread prose
    # like "cannot COMPLETE yet" or "CANNOT COMPLETE", flipping the
    # pipeline UI / last_verdict / analytics to a false success.
    verdict = 'unknown'
    last_non_empty = ''
    for line in reversed(content.splitlines()):
        stripped = line.strip()
        if stripped:
            last_non_empty = stripped
            break
    if last_non_empty == 'COMPLETE':
        verdict = 'complete'
    else:
        # The advanced/stalled/regressed markers come from explicit
        # verdict prose inside the body (not a terminal line), so
        # the legacy substring check is retained for those.
        for v in ('advanced', 'stalled', 'regressed'):
            if v in content.lower():
                verdict = v
                break

    p_issues = {}
    for match in re.finditer(r'\[P(\d)\]', content):
        level = f'P{match.group(1)}'
        p_issues[level] = p_issues.get(level, 0) + 1

    return {
        'content': _to_bilingual(content),
        'verdict': verdict,
        'p_issues': p_issues,
        'mtime': os.path.getmtime(filepath),
    }


def parse_session(session_dir, project_dir=None):
    """Parse a complete RLCR session directory into a structured dict.

    ``project_dir`` is the project root from which ``git`` status is
    probed for the active-card display. When omitted, the project root
    is derived from the session path (``.humanize/rlcr/<session>``).
    """
    session_id = os.path.basename(session_dir)
    status = detect_session_status(session_dir)
    state = parse_state(session_dir)
    goal_tracker = parse_goal_tracker(session_dir)

    if project_dir is None:
        project_dir = _derive_project_root(session_dir)

    current_round = state.get('current_round', 0)

    # Discover the highest round index present on disk (review files may exceed current_round)
    max_disk_round = current_round
    for f in os.listdir(session_dir):
        m = re.match(r'round-(\d+)-(?:summary|review-result)\.md$', f)
        if m:
            max_disk_round = max(max_disk_round, int(m.group(1)))

    # Build rounds from 0..max(current_round, highest on-disk round)
    rounds = []
    prev_mtime = None
    for rn in range(max_disk_round + 1):
        summary_file = os.path.join(session_dir, f'round-{rn}-summary.md')
        review_file = os.path.join(session_dir, f'round-{rn}-review-result.md')

        summary = parse_round_summary(summary_file)
        review = parse_review_result(review_file)

        # Duration from consecutive summary timestamps
        duration_minutes = None
        if summary and prev_mtime is not None:
            duration_minutes = round((summary['mtime'] - prev_mtime) / 60, 1)
        if summary:
            prev_mtime = summary['mtime']

        # Per-round task progress: only from explicit patterns in this round's summary
        task_progress = summary.get('task_progress') if summary else None

        rounds.append({
            'number': rn,
            'phase': _determine_phase(session_dir, rn, status, current_round),
            'summary': summary['content'] if summary else {'zh': None, 'en': None},
            'review_result': review['content'] if review else {'zh': None, 'en': None},
            'verdict': review['verdict'] if review else 'unknown',
            'bitlesson_delta': summary['bitlesson_delta'] if summary else 'none',
            'duration_minutes': duration_minutes,
            'p_issues': review['p_issues'] if review else {},
            'task_progress': task_progress,
            # summary mtime is the round-complete timestamp; the
            # analyzer consumes it for the "rounds per day" strip on
            # the home page. Stays None for rounds whose summary has
            # not landed yet.
            'summary_mtime': summary['mtime'] if summary else None,
        })

    # Task/AC progress from goal tracker
    tasks_done = 0
    tasks_total = 0
    tasks_active = 0
    tasks_deferred = 0
    ac_done = 0
    ac_total = 0
    ultimate_goal = ''
    if goal_tracker:
        tasks_total = len(goal_tracker['active_tasks']) + len(goal_tracker['completed_verified'])
        tasks_done = len(goal_tracker['completed_verified'])
        # Active tasks = rows in the Active-Tasks table whose status
        # is neither "completed" nor "deferred". Matches the shell
        # parser used by `humanize monitor rlcr` (see
        # scripts/humanize.sh:humanize_parse_goal_tracker).
        tasks_active = sum(
            1 for t in goal_tracker['active_tasks']
            if (t.get('status') or '').strip().lower() not in ('completed', 'deferred')
        )
        tasks_deferred = len(goal_tracker.get('deferred_tasks', []))
        ac_total = len(goal_tracker['acceptance_criteria'])
        ac_done = sum(1 for ac in goal_tracker['acceptance_criteria'] if ac['status'] == 'completed')
        ultimate_goal = goal_tracker.get('ultimate_goal', '') or ''

    # Methodology report (bilingual)
    report_file = os.path.join(session_dir, 'methodology-analysis-report.md')
    methodology_report = {'zh': None, 'en': None}
    if os.path.exists(report_file):
        try:
            with open(report_file, 'r', encoding='utf-8') as f:
                raw_report = f.read()
            methodology_report = _to_bilingual(raw_report)
        except (PermissionError, OSError):
            pass

    # Compute session duration from first/last round timestamps
    session_duration_minutes = None
    if len(rounds) >= 2:
        first_mtime = None
        last_mtime = None
        for rn in range(current_round + 1):
            sf = os.path.join(session_dir, f'round-{rn}-summary.md')
            if os.path.exists(sf):
                mt = os.path.getmtime(sf)
                if first_mtime is None:
                    first_mtime = mt
                last_mtime = mt
        if first_mtime and last_mtime and last_mtime > first_mtime:
            session_duration_minutes = round((last_mtime - first_mtime) / 60, 1)

    # started_at
    started_at = state.get('started_at', '')
    if not started_at:
        try:
            dt = datetime.strptime(session_id, '%Y-%m-%d_%H-%M-%S')
            started_at = dt.isoformat() + 'Z'
        except ValueError:
            started_at = ''

    build_finish_round, skip_impl = parse_review_phase_marker(session_dir)
    cache_logs = cache_logs_for_session(project_dir, session_id)
    # Mirror the CLI `humanize monitor rlcr` Log: line by preferring
    # codex-run at the highest round, falling back through the other
    # (tool, role) combos. cache_logs is already sorted by
    # (round, tool, role) but simply taking the last entry can land
    # on a gemini-review/codex-review file for the same round, which
    # is a secondary stream rather than the primary one the CLI
    # monitor and users expect.
    active_log_path = ''
    if cache_logs:
        max_round = max(entry['round'] for entry in cache_logs)
        preference = (
            ('codex', 'run'),
            ('codex', 'review'),
            ('gemini', 'run'),
            ('gemini', 'review'),
        )
        for tool, role in preference:
            match = next(
                (entry for entry in cache_logs
                 if entry['round'] == max_round
                 and entry['tool'] == tool
                 and entry['role'] == role),
                None,
            )
            if match is not None:
                active_log_path = match['path']
                break
        if not active_log_path:
            # Defensive fallback: pick the last entry at the top
            # round so the dashboard still surfaces something.
            top_round_entries = [e for e in cache_logs if e['round'] == max_round]
            active_log_path = (top_round_entries or cache_logs)[-1]['path']

    return {
        'id': session_id,
        'status': status,
        'current_round': current_round,
        'max_iterations': state.get('max_iterations', 42),
        'full_review_round': state.get('full_review_round'),
        'plan_file': state.get('plan_file', ''),
        'start_branch': state.get('start_branch', ''),
        'base_branch': state.get('base_branch', ''),
        'started_at': started_at,
        'codex_model': state.get('codex_model', ''),
        'codex_effort': state.get('codex_effort', ''),
        'ask_codex_question': bool(state.get('ask_codex_question', False)),
        'review_started': bool(state.get('review_started', False)),
        'agent_teams': bool(state.get('agent_teams', False)),
        'push_every_round': bool(state.get('push_every_round', False)),
        'mainline_stall_count': int(state.get('mainline_stall_count', 0) or 0),
        'last_mainline_verdict': state.get('last_mainline_verdict', 'unknown'),
        'build_finish_round': build_finish_round,
        'skip_impl': skip_impl,
        'last_verdict': rounds[-1]['verdict'] if rounds else 'unknown',
        'drift_status': state.get('drift_status', 'normal'),
        'rounds': rounds,
        'goal_tracker': goal_tracker,
        'methodology_report': methodology_report,
        'tasks_done': tasks_done,
        'tasks_total': tasks_total,
        'tasks_active': tasks_active,
        'tasks_deferred': tasks_deferred,
        'ac_done': ac_done,
        'ac_total': ac_total,
        'ultimate_goal': ultimate_goal,
        'duration_minutes': session_duration_minutes,
        'cache_logs': cache_logs,
        'active_log_path': active_log_path,
        'git_status': parse_git_status(project_dir) if status in ('active', 'analyzing', 'finalizing') else None,
    }


def _determine_phase(session_dir, round_num, session_status, current_round=None):
    """Determine the phase of a specific round.

    The ``finalize`` classification applies ONLY to the live finalize
    step (the round currently in progress when the session entered
    ``finalize-state.md``). Earlier rounds keep their original
    ``implementation`` / ``code_review`` classification so the
    dashboard timeline preserves the real per-round breakdown
    instead of relabelling everything as finalize.
    """
    review_started_file = os.path.join(session_dir, '.review-phase-started')
    if os.path.exists(review_started_file):
        try:
            with open(review_started_file, 'r') as f:
                content = f.read()
            match = re.search(r'build_finish_round=(\d+)', content)
            if match:
                build_round = int(match.group(1))
                # Skip-impl sessions never ran a build round; setup-
                # rlcr-loop.sh writes skip_impl=true alongside the
                # build_finish_round=0 line so the marker is
                # distinguishable from a normal-mode session whose
                # first round (index 0) was the last build round. Every
                # round including round 0 is review-only work in that
                # case.
                if re.search(r'^skip_impl=true\s*$', content, re.MULTILINE):
                    return 'code_review'
                if round_num > build_round:
                    return 'code_review'
        except (PermissionError, OSError):
            pass

    if (session_status == 'finalizing'
            and current_round is not None
            and round_num == current_round):
        return 'finalize'

    return 'implementation'


def is_valid_session(session_dir):
    """Check if a session directory has minimum required files."""
    has_state = os.path.exists(os.path.join(session_dir, 'state.md'))
    has_terminal = any(
        f.endswith('-state.md') and f != 'state.md'
        for f in os.listdir(session_dir)
        if os.path.isfile(os.path.join(session_dir, f))
    )
    return has_state or has_terminal


def list_sessions(project_dir):
    """List all RLCR sessions in a project directory."""
    rlcr_dir = os.path.join(project_dir, '.humanize', 'rlcr')
    if not os.path.isdir(rlcr_dir):
        return []

    sessions = []
    for entry in sorted(os.listdir(rlcr_dir), reverse=True):
        session_dir = os.path.join(rlcr_dir, entry)
        if not os.path.isdir(session_dir):
            continue

        if not is_valid_session(session_dir):
            logger.warning("Skipping malformed session directory: %s (no state.md or terminal state file)", entry)
            continue

        try:
            session = parse_session(session_dir, project_dir=project_dir)
            sessions.append(session)
        except Exception as e:
            logger.warning("Failed to parse session %s: %s", entry, e)
            continue

    return sessions


def read_plan_file(session_dir, project_dir):
    """Read the plan file for a session.

    Defense-in-depth path validation: `plan_file` in state.md is
    operator-controlled text. Without bounds, a crafted value like
    `plan_file: ../secret.txt` or `plan_file: /etc/passwd` would
    make /api/sessions/<id>/plan read arbitrary host files (since
    os.path.join silently accepts absolute second-arg overrides and
    does not stop parent traversal). Validate the resolved path
    stays inside the project tree OR the session directory (the
    session-local plan.md backup is legitimate) before reading.
    On validation failure, fall back to the session-local backup.
    """
    state = parse_state(session_dir)
    plan_path = state.get('plan_file', '')

    backup = os.path.join(session_dir, 'plan.md')

    def _read_backup():
        if os.path.exists(backup):
            with open(backup, 'r', encoding='utf-8') as f:
                return f.read()
        return None

    if not plan_path:
        return _read_backup()

    try:
        candidate = os.path.join(project_dir, plan_path)
        candidate_real = os.path.realpath(candidate)
        project_real = os.path.realpath(project_dir)
        session_real = os.path.realpath(session_dir)
    except (OSError, ValueError):
        return _read_backup()

    project_prefix = project_real.rstrip(os.sep) + os.sep
    session_prefix = session_real.rstrip(os.sep) + os.sep
    inside_project = (
        candidate_real == project_real
        or candidate_real.startswith(project_prefix)
    )
    inside_session = (
        candidate_real == session_real
        or candidate_real.startswith(session_prefix)
    )
    if not (inside_project or inside_session):
        return _read_backup()

    if os.path.exists(candidate_real):
        with open(candidate_real, 'r', encoding='utf-8') as f:
            return f.read()

    return _read_backup()
