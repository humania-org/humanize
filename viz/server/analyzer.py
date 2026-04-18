"""Cross-session analytics for RLCR loop data.

Computes statistics across multiple sessions: efficiency metrics,
quality indicators, verdict distributions, and BitLesson growth.
"""

import time


def _rounds_per_day(sessions, window_days=14):
    """Return a ``window_days``-length list of rounds-completed-per-day.

    Buckets round-complete timestamps (the round's summary mtime) into
    calendar days anchored at the current local midnight, so the
    tail entry always represents "today" and the head entry is
    ``window_days - 1`` days ago. Consumed by the home-page analytics
    strip to drive a compact sparkline.
    """
    if window_days <= 0:
        return []
    now = time.time()
    # Anchor bucket boundaries at local midnight for stable day-aligned
    # buckets regardless of call time.
    tm_today = time.localtime(now)
    midnight_today = time.mktime(time.struct_time((
        tm_today.tm_year, tm_today.tm_mon, tm_today.tm_mday,
        0, 0, 0, 0, 0, tm_today.tm_isdst,
    )))
    earliest = midnight_today - (window_days - 1) * 86400

    buckets = [0] * window_days
    for s in sessions:
        for r in s.get('rounds', []):
            ts = r.get('summary_mtime')
            if ts is None or ts < earliest:
                continue
            # Offset from the earliest bucket's midnight; floor-div to
            # the matching bucket index (clamped to the window tail
            # for timestamps that fall on or after today's midnight).
            idx = int((ts - earliest) // 86400)
            if idx < 0:
                continue
            if idx >= window_days:
                idx = window_days - 1
            buckets[idx] += 1
    return buckets


def compute_analytics(sessions):
    """Compute cross-session statistics from a list of parsed sessions."""
    if not sessions:
        return _empty_analytics()

    total = len(sessions)
    completed = sum(1 for s in sessions if s['status'] == 'complete')
    total_rounds = [s['current_round'] for s in sessions if s['current_round'] > 0]
    avg_rounds = round(sum(total_rounds) / len(total_rounds), 1) if total_rounds else 0
    rounds_per_day = _rounds_per_day(sessions, window_days=14)

    # Verdict distribution — only count rounds that have an actual review result
    verdict_counts = {'advanced': 0, 'stalled': 0, 'regressed': 0, 'complete': 0}
    for s in sessions:
        for r in s['rounds']:
            if r.get('review_result') is None:
                continue
            v = r.get('verdict', 'unknown')
            if v != 'unknown':
                verdict_counts[v] = verdict_counts.get(v, 0) + 1

    # P0-P9 distribution
    p_distribution = {}
    for s in sessions:
        for r in s['rounds']:
            for level, count in r.get('p_issues', {}).items():
                p_distribution[level] = p_distribution.get(level, 0) + count

    # Per-session stats for charts
    session_stats = []
    cumulative_bitlesson = 0
    bitlesson_growth = []

    for s in sessions:
        rounds_count = s['current_round']

        # Average round duration
        durations = [r['duration_minutes'] for r in s['rounds'] if r.get('duration_minutes')]
        avg_duration = round(sum(durations) / len(durations), 1) if durations else None

        # First COMPLETE round
        first_complete = None
        for r in s['rounds']:
            if r.get('verdict') == 'complete':
                first_complete = r['number']
                break

        # Rework count (rounds after review phase started)
        rework = 0
        in_review = False
        for r in s['rounds']:
            if r.get('phase') == 'code_review':
                in_review = True
            if in_review:
                rework += 1

        # Verdict breakdown for this session
        sv = {'advanced': 0, 'stalled': 0, 'regressed': 0}
        for r in s['rounds']:
            v = r.get('verdict', '')
            if v in sv:
                sv[v] += 1

        # BitLesson count
        bl_count = sum(1 for r in s['rounds'] if r.get('bitlesson_delta') in ('add', 'update'))
        cumulative_bitlesson += bl_count

        bitlesson_growth.append({
            'session_id': s['id'],
            'cumulative': cumulative_bitlesson,
            'delta': bl_count,
        })

        session_stats.append({
            'session_id': s['id'],
            'status': s['status'],
            'rounds': rounds_count,
            'avg_duration_minutes': avg_duration,
            'first_complete_round': first_complete,
            'rework_count': rework,
            'ac_completion_rate': round(s['ac_done'] / s['ac_total'] * 100, 1) if s['ac_total'] > 0 else 0,
            'verdict_breakdown': sv,
        })

    # Total BitLessons (count from bitlesson.md if available, else estimate)
    total_bitlessons = cumulative_bitlesson

    return {
        'overview': {
            'total_sessions': total,
            'completed_sessions': completed,
            'completion_rate': round(completed / total * 100, 1) if total > 0 else 0,
            'average_rounds': avg_rounds,
            'total_bitlessons': total_bitlessons,
            'rounds_per_day': rounds_per_day,
            'rounds_per_day_window': 14,
        },
        'verdict_distribution': verdict_counts,
        'p_distribution': p_distribution,
        'session_stats': session_stats,
        'bitlesson_growth': bitlesson_growth,
    }


def _empty_analytics():
    """Return empty analytics structure."""
    return {
        'overview': {
            'total_sessions': 0,
            'completed_sessions': 0,
            'completion_rate': 0,
            'average_rounds': 0,
            'total_bitlessons': 0,
            'rounds_per_day': [0] * 14,
            'rounds_per_day_window': 14,
        },
        'verdict_distribution': {},
        'p_distribution': {},
        'session_stats': [],
        'bitlesson_growth': [],
    }
