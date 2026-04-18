/* Chart.js analytics v3 */
console.log('[charts] v3 loaded')

const _charts = {}

function _colors() {
    const s = getComputedStyle(document.documentElement)
    const g = k => s.getPropertyValue(k).trim()
    return {
        accent: g('--accent') || '#d97757',
        success: g('--verdict-advanced') || '#6ee7a0',
        warning: g('--verdict-stalled') || '#fbbf24',
        danger: g('--verdict-regressed') || '#f87171',
        info: g('--verdict-active') || '#60a5fa',
        purple: g('--verdict-complete') || '#a78bfa',
        muted: g('--verdict-unknown') || '#6b7280',
        text: g('--text-2') || '#8a877f',
        gridLine: g('--border-1') || 'rgba(255,255,255,0.06)',
        bg2: g('--bg-2') || '#1e1e24',
    }
}

function _baseOpts(c) {
    return {
        responsive: true,
        maintainAspectRatio: false,
        animation: { duration: 600 },
        plugins: {
            legend: { display: false },
            tooltip: { backgroundColor: c.bg2, titleColor: c.text, bodyColor: c.text, borderColor: c.accent, borderWidth: 1, cornerRadius: 8, padding: 10 },
        },
        scales: {
            x: { ticks: { color: c.text, font: { size: 10 } }, grid: { color: c.gridLine }, border: { color: c.gridLine } },
            y: { ticks: { color: c.text, font: { size: 10 } }, grid: { color: c.gridLine }, border: { color: c.gridLine }, beginAtZero: true },
        }
    }
}

function _noScaleOpts(c) {
    return {
        responsive: true,
        maintainAspectRatio: false,
        animation: { duration: 600 },
        plugins: {
            legend: { position: 'right', labels: { color: c.text, font: { size: 11 }, padding: 12, usePointStyle: true, pointStyleWidth: 10 } },
            tooltip: { backgroundColor: c.bg2, titleColor: c.text, bodyColor: c.text, borderColor: c.accent, borderWidth: 1, cornerRadius: 8, padding: 10 },
        },
    }
}

function _showEmpty(canvasId, msg) {
    const el = document.getElementById(canvasId)
    if (!el) return
    el.parentElement.innerHTML = `<div style="display:flex;align-items:center;justify-content:center;height:100%;color:var(--text-3);font-size:0.85rem;font-style:italic">${msg}</div>`
}

function _makeChart(canvasId, config) {
    const el = document.getElementById(canvasId)
    if (!el) { console.warn('[charts] canvas not found:', canvasId); return null }
    try {
        return new Chart(el, config)
    } catch (e) {
        console.error('[charts] failed to create', canvasId, e)
        return null
    }
}

function buildCharts(data) {
    // Destroy previous charts
    Object.values(_charts).forEach(ch => { try { ch.destroy() } catch(e) {} })
    for (const k of Object.keys(_charts)) delete _charts[k]

    const c = _colors()
    const stats = data.session_stats || []
    const labels = stats.map(s => s.session_id.slice(5, 16).replace('_', ' '))

    console.log('[charts] buildCharts called, stats:', stats.length, 'el c-rounds:', !!document.getElementById('c-rounds'))

    // 1. Rounds per session
    if (stats.length > 0) {
        const ch = _makeChart('c-rounds', {
            type: stats.length === 1 ? 'bar' : 'line',
            data: { labels, datasets: [{ label: 'Rounds', data: stats.map(s => s.rounds), borderColor: c.accent, backgroundColor: stats.length === 1 ? c.accent + 'cc' : c.accent + '18', fill: stats.length > 1, tension: 0.4, pointRadius: 5, pointBackgroundColor: c.accent, borderRadius: 6, barThickness: 40 }] },
            options: _baseOpts(c),
        })
        if (ch) _charts.rounds = ch
    } else {
        _showEmpty('c-rounds', 'No session data yet')
    }

    // 2. Avg round duration
    if (stats.some(s => s.avg_duration_minutes != null)) {
        const ch = _makeChart('c-duration', {
            type: 'bar',
            data: { labels, datasets: [{ label: 'Avg Duration (min)', data: stats.map(s => s.avg_duration_minutes), backgroundColor: c.info + 'aa', borderColor: c.info, borderWidth: 1, borderRadius: 6, barThickness: 40 }] },
            options: _baseOpts(c),
        })
        if (ch) _charts.dur = ch
    } else {
        _showEmpty('c-duration', 'No duration data available')
    }

    // 3. Verdict distribution (doughnut)
    const vd = data.verdict_distribution || {}
    const vdEntries = Object.entries(vd).filter(([_, v]) => v > 0)
    if (vdEntries.length > 0) {
        const colorMap = { advanced: c.success, stalled: c.warning, regressed: c.danger, complete: c.purple, unknown: c.muted }
        const ch = _makeChart('c-verdicts', {
            type: 'doughnut',
            data: { labels: vdEntries.map(([k]) => k), datasets: [{ data: vdEntries.map(([_, v]) => v), backgroundColor: vdEntries.map(([k]) => colorMap[k] || c.muted), borderWidth: 2, borderColor: c.bg2 }] },
            options: _noScaleOpts(c),
        })
        if (ch) _charts.v = ch
    } else {
        _showEmpty('c-verdicts', 'No reviewed rounds yet')
    }

    // 4. P-issues distribution
    const pd = data.p_distribution || {}
    const pk = Object.keys(pd).sort()
    if (pk.length > 0) {
        const palette = [c.danger, c.warning, c.accent, c.info, c.success, c.purple, c.muted]
        const ch = _makeChart('c-pissues', {
            type: 'bar',
            data: { labels: pk, datasets: [{ label: 'Issues', data: pk.map(k => pd[k]), backgroundColor: pk.map((_, i) => palette[i % palette.length] + 'bb'), borderColor: pk.map((_, i) => palette[i % palette.length]), borderWidth: 1, borderRadius: 6 }] },
            options: _baseOpts(c),
        })
        if (ch) _charts.p = ch
    } else {
        _showEmpty('c-pissues', 'No P0-P9 issues recorded')
    }

    // 5. First COMPLETE round
    const fcData = stats.filter(s => s.first_complete_round != null && s.first_complete_round > 0)
    if (fcData.length > 0) {
        const ch = _makeChart('c-fc', {
            type: fcData.length === 1 ? 'bar' : 'line',
            data: { labels: fcData.map(s => s.session_id.slice(5, 16).replace('_', ' ')), datasets: [{ label: 'First COMPLETE at Round', data: fcData.map(s => s.first_complete_round), borderColor: c.success, backgroundColor: fcData.length === 1 ? c.success + 'cc' : c.success + '18', fill: fcData.length > 1, tension: 0.4, pointRadius: 5, pointBackgroundColor: c.success, borderRadius: 6, barThickness: 40 }] },
            options: _baseOpts(c),
        })
        if (ch) _charts.fc = ch
    } else {
        _showEmpty('c-fc', 'No sessions reached COMPLETE yet')
    }

    // 6. BitLesson growth
    const bl = data.bitlesson_growth || []
    if (bl.length > 0 && bl.some(b => b.cumulative > 0)) {
        const ch = _makeChart('c-bl', {
            type: bl.length === 1 ? 'bar' : 'line',
            data: { labels: bl.map(b => b.session_id.slice(5, 16).replace('_', ' ')), datasets: [{ label: 'Cumulative BitLessons', data: bl.map(b => b.cumulative), borderColor: c.accent, backgroundColor: bl.length === 1 ? c.accent + 'cc' : c.accent + '25', fill: bl.length > 1, tension: 0.4, pointRadius: 5, pointBackgroundColor: c.accent, borderRadius: 6, barThickness: 40 }] },
            options: _baseOpts(c),
        })
        if (ch) _charts.bl = ch
    } else {
        _showEmpty('c-bl', 'No BitLesson entries yet')
    }
}
