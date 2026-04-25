/* Main SPA — router, WebSocket, token propagation, page rendering */

let ws = null, wsRetryDelay = 1000
const WS_MAX_RETRY = 30000
let _sortCol = 'session_id', _sortAsc = false
const _liveLogPanes = new Map() // sessionId -> { eventSource, element, basename }

// ─── Auth token propagation (T11-frontend) ───
//
// Resolved once per page load. Order of precedence:
//   1. ?token=<tok> on the document URL (single-use, stripped from
//      the visible URL once consumed but kept in sessionStorage so
//      reloads work without manual re-entry).
//   2. #token=<tok> in the URL hash (same as above; supports clients
//      that prefer the hash form for security on shared screens).
//   3. sessionStorage cached token from a prior visit.
//   4. <meta name="humanize-viz-token" content="..."> baked into the
//      static index.html (uncommon; useful for kiosk deployments).
//
// On localhost-bound deployments the server skips auth entirely, so a
// missing token is fine and api() will simply not attach a header.
function _resolveAuthToken() {
    let token = ''
    try {
        const url = new URL(location.href)
        const queryToken = url.searchParams.get('token')
        if (queryToken) {
            token = queryToken
            url.searchParams.delete('token')
            history.replaceState(null, '', url.toString())
        }
    } catch (_) {}

    if (!token && location.hash.includes('token=')) {
        const m = location.hash.match(/(?:^|[#&])token=([^&]+)/)
        if (m) {
            token = decodeURIComponent(m[1])
            const newHash = location.hash.replace(/(^|[#&])token=[^&]+&?/, '$1').replace(/&$/, '')
            history.replaceState(null, '', location.pathname + location.search + newHash)
        }
    }

    if (!token) {
        token = sessionStorage.getItem('humanize-viz-token') || ''
    }

    if (!token) {
        const meta = document.querySelector('meta[name="humanize-viz-token"]')
        if (meta) token = meta.getAttribute('content') || ''
    }

    if (token) {
        sessionStorage.setItem('humanize-viz-token', token)
    }
    return token
}

const _authToken = _resolveAuthToken()

function _withToken(url) {
    if (!_authToken) return url
    const sep = url.includes('?') ? '&' : '?'
    return `${url}${sep}token=${encodeURIComponent(_authToken)}`
}

// ─── WebSocket (localhost coarse events only; remote mode is rejected
// server-side per DEC-4) ───
//
// Remote mode is detected by the presence of a resolved auth token:
// localhost-bound deployments do not set one (the server does not
// enforce auth), so a token implies the dashboard is talking to a
// non-loopback server where WS is rejected. In that case the home
// page falls back to polling /api/sessions on a fixed interval to
// surface WAITING -> live transitions and EOF transitions in the UI.
const _isRemoteMode = !!_authToken

function connectWebSocket() {
    if (_isRemoteMode) {
        // No coarse session-list channel exists in remote mode (per
        // DEC-4); the home-route polling loop handles refreshes.
        return
    }
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:'
    const wsUrl = _withToken(`${proto}//${location.host}/ws`)
    ws = new WebSocket(wsUrl)
    ws.onopen = () => { wsRetryDelay = 1000 }
    ws.onmessage = (e) => {
        try {
            const msg = JSON.parse(e.data)
            const route = parseRoute()
            // Targeted subtree refresh per event type — avoid the
            // whole-page rebuild that previously caused flicker on
            // every file write. Only the affected DOM subtree is
            // touched; the live-log <pre> (SSE) and the page
            // skeleton are never recreated here.
            if (route.page === 'home') {
                _scheduleHomeRefresh()
            } else if (route.page === 'session' && route.id === msg.session_id) {
                _scheduleSessionPartialRefresh(route.id, msg.type)
            }
        } catch (_) {}
    }
    ws.onclose = () => {
        setTimeout(() => {
            wsRetryDelay = Math.min(wsRetryDelay * 2, WS_MAX_RETRY)
            connectWebSocket()
        }, wsRetryDelay)
    }
}

// ─── Targeted WS-push refresh ───
//
// Rather than polling or re-rendering the whole page on every
// watcher broadcast, the WS onmessage path dispatches per event
// type to the smallest subtree that changed:
//   - home: re-build the active / completed card lists only.
//   - session-detail: re-run renderPipeline / renderSessionSidebar /
//     renderGoalBar as appropriate, never touching the
//     #session-log-container or its EventSource.
//
// A ~500ms trailing-edge debounce per surface coalesces bursts
// (state.md + goal-tracker.md + round-N-summary.md often land in the
// same second) so the reader sees one update, not three.
const _PARTIAL_DEBOUNCE_MS = 500

let _homeRefreshHandle = null
function _scheduleHomeRefresh() {
    if (_homeRefreshHandle != null) return
    _homeRefreshHandle = setTimeout(() => {
        _homeRefreshHandle = null
        if (parseRoute().page === 'home') _refreshHomeCards()
    }, _PARTIAL_DEBOUNCE_MS)
}

let _sessionRefreshHandle = null
let _pendingSessionRefreshKinds = new Set()
function _scheduleSessionPartialRefresh(sessionId, eventType) {
    // Merge the kinds of updates we need to do so a burst that mixes
    // round_added + session_updated fires one refresh with both
    // subtrees updated.
    if (eventType) _pendingSessionRefreshKinds.add(eventType)
    if (_sessionRefreshHandle != null) return
    _sessionRefreshHandle = setTimeout(async () => {
        _sessionRefreshHandle = null
        const kinds = _pendingSessionRefreshKinds
        _pendingSessionRefreshKinds = new Set()
        const route = parseRoute()
        if (route.page !== 'session' || route.id !== sessionId) return
        await _refreshSessionPartial(sessionId, kinds)
    }, _PARTIAL_DEBOUNCE_MS)
}

// Diff-based refresh of the home sessions region. Only cards whose
// rendered content actually changed get their outerHTML replaced;
// unchanged cards are left entirely alone so there is no re-render,
// no re-animation, and no observable "flashing". Section skeletons
// (labels + list containers) are created or torn down as needed when
// a session transitions between Active and Completed, but that
// touches only the affected section — existing cards in the other
// section do not move.
async function _refreshHomeCards() {
    const wrap = document.getElementById('home-sessions')
    if (!wrap) return
    const sessions = await api('/api/sessions').catch(() => null)
    if (sessions == null) return
    if (parseRoute().page !== 'home') return

    // Empty state transition in either direction falls back to the
    // full rebuild (rare: at most once when the first session lands
    // or when the last one is pruned). This never fires during a
    // running loop.
    const currentlyEmpty = wrap.querySelector('.empty') != null
    if (sessions.length === 0) {
        if (!currentlyEmpty) wrap.innerHTML = _buildHomeSessionsHtml(sessions)
        return
    }
    if (currentlyEmpty) {
        wrap.innerHTML = _buildHomeSessionsHtml(sessions)
        return
    }

    const active = sessions.filter(s => ['active', 'analyzing', 'finalizing'].includes(s.status))
    const finished = sessions.filter(s => !['active', 'analyzing', 'finalizing'].includes(s.status))

    _applyHomeSection(wrap, 'active', active, t('home.active'), 'session-grid', activeSessionPane)
    _applyHomeSection(wrap, 'completed', finished, t('home.completed'), 'session-grid', sessionCard)
}

// Ensure a section (label + list container) matches the given
// session list. Cards are diff-updated by data-session-id:
//   - stays the same (same HTML) -> untouched
//   - content changed            -> outerHTML swap on that one card
//   - new session in list        -> append
//   - session dropped from list  -> remove
// Section label + list container are created lazily when the list
// becomes non-empty and removed when it goes back to empty.
function _applyHomeSection(wrap, sectionKey, list, label, containerClass, cardFn) {
    const listSel = `[data-home-section="${sectionKey}"]`
    let container = wrap.querySelector(listSel)
    const labelSel = `[data-home-section-label="${sectionKey}"]`
    let labelEl = wrap.querySelector(labelSel)

    if (list.length === 0) {
        if (labelEl) labelEl.remove()
        if (container) container.remove()
        return
    }

    if (!container) {
        // Create label + container and place them in the right order.
        // active section goes first; completed second.
        const labelHtml = `<div class="eyebrow-rule${sectionKey === 'completed' ? ' completed' : ''}" data-home-section-label="${sectionKey}">${label}</div>`
        const containerHtml = `<div class="${containerClass}" data-home-section="${sectionKey}"></div>`
        if (sectionKey === 'active') {
            wrap.insertAdjacentHTML('afterbegin', labelHtml + containerHtml)
        } else {
            wrap.insertAdjacentHTML('beforeend', labelHtml + containerHtml)
        }
        container = wrap.querySelector(listSel)
    }

    // Index existing cards by session id.
    const existing = new Map()
    for (const el of container.querySelectorAll('.session-card[data-session-id]')) {
        existing.set(el.dataset.sessionId, el)
    }

    const seen = new Set()
    let cursor = null
    for (const s of list) {
        seen.add(s.id)
        const html = cardFn(s).trim()
        const el = existing.get(s.id)
        if (el) {
            // Compare rendered HTML; skip if identical.
            if (el.outerHTML.trim() !== html) {
                const tmp = document.createElement('div')
                tmp.innerHTML = html
                el.replaceWith(tmp.firstElementChild)
            }
            cursor = container.querySelector(`.session-card[data-session-id="${CSS.escape(s.id)}"]`)
        } else {
            // Append new card at the current position.
            const tmp = document.createElement('div')
            tmp.innerHTML = html
            const node = tmp.firstElementChild
            node.classList.add('js-card-new')
            if (cursor && cursor.nextSibling) {
                container.insertBefore(node, cursor.nextSibling)
            } else {
                container.appendChild(node)
            }
            cursor = node
        }
    }

    // Remove cards for sessions that are no longer in this section.
    for (const [id, el] of existing) {
        if (!seen.has(id)) el.remove()
    }
}

// Targeted session-detail refresh. Re-runs only the subtrees implied
// by the set of event kinds, leaving the rest of the DOM (notably
// the live-log <pre> and its EventSource) untouched.
async function _refreshSessionPartial(sessionId, kinds) {
    const session = await api(`/api/sessions/${sessionId}`)
    if (!session) return
    // Route-change race guard: the fetch above is async, so by the
    // time the response lands the user may have navigated to another
    // session or route. Checking the DOM skeleton + current route
    // prevents us from writing stale data into the wrong page.
    const route = parseRoute()
    if (route.page !== 'session' || route.id !== sessionId) return
    const layout = document.querySelector(`.detail-layout[data-session-id="${CSS.escape(sessionId)}"]`)
    if (!layout) return
    // Pipeline update runs for every session-scoped event kind,
    // including session_updated: a review-result.md write flips the
    // verdict on an existing node, which must re-paint that one
    // node's dot / badge. The incremental updater is a no-op on
    // rounds whose verdict and active flag are unchanged, so running
    // it unconditionally is cheap.
    const wantPipeline = kinds.has('round_added') || kinds.has('session_updated') || kinds.has('session_finished')
    const wantSidebar  = kinds.has('round_added') || kinds.has('session_updated') || kinds.has('session_finished')
    const wantGoalBar  = kinds.has('round_added') || kinds.has('session_updated') || kinds.has('session_finished')
    window._currentSession = session
    if (wantPipeline) {
        const root = document.getElementById('pipeline-root')
        if (root) {
            // Incremental update keeps the user's zoom/pan and only
            // adds / mutates the specific nodes that changed. Full
            // renderPipeline is still used on first entry because it
            // also sets up the viewport + drag listeners; this
            // targeted path assumes those already exist.
            if (typeof window._updatePipelineIncremental === 'function') {
                window._updatePipelineIncremental(root, session)
            } else {
                renderPipeline(root, session)
            }
        }
    }
    if (wantSidebar) renderSessionSidebar(session)
    if (wantGoalBar) renderGoalBar(session)
    // Keep the layout mode in sync (e.g. session finished -> hide log
    // row) and let _ensureSessionLogPane idempotently roll forward
    // to a newer cache-log basename when a new round starts.
    _applyDetailLayoutMode(session)
    _ensureSessionLogPane(session)
    const cancelBtn = document.getElementById('ops-cancel')
    const CANCELLABLE = ['active', 'analyzing', 'finalizing']
    if (cancelBtn) cancelBtn.style.display = CANCELLABLE.includes(session.status) ? '' : 'none'
}

// Remote-mode metadata polling. In localhost mode the WebSocket
// carries watcher events, so there is no polling on top of that.
// In remote mode WS is rejected server-side (DEC-4), so without a
// fallback the card counters, pipeline nodes, and methodology
// status would all freeze at page-load state. This polling uses the
// same targeted refresh helpers (_refreshHomeCards /
// _refreshSessionPartial) that the WS path uses, so it does NOT
// rebuild the page — it only updates the same in-place subtrees
// and leaves the SSE log pane alone.
const _REMOTE_POLL_INTERVAL_MS = 10000
let _remotePollHandle = null
let _remotePollRoute = null

function _startRemotePolling() {
    if (!_isRemoteMode) return
    if (_remotePollHandle != null) return
    _remotePollHandle = setInterval(() => {
        const route = parseRoute()
        _remotePollRoute = route
        if (route.page === 'home') {
            _refreshHomeCards()
        } else if (route.page === 'session') {
            // Feed a synthetic "session_updated" kind so the
            // refresh runs pipeline + sidebar + goal-bar + log pane
            // — matching what the WS path does on catch-up.
            _scheduleSessionPartialRefresh(route.id, 'session_updated')
        }
    }, _REMOTE_POLL_INTERVAL_MS)
}

// Kept for the teardown path in renderCurrentRoute / toggleTheme.
// Localhost mode doesn't poll so these are no-ops for the common
// path; remote mode stops via _stopRemotePolling on route change.
function _stopHomePolling() {}
function _stopSessionPolling() {}
function _stopRemotePolling() {
    if (_remotePollHandle != null) {
        clearInterval(_remotePollHandle)
        _remotePollHandle = null
    }
}

// ─── Router ───
function parseRoute() {
    const h = location.hash || '#/'
    if (h === '#/' || h === '#') return { page: 'home' }
    let m = h.match(/^#\/session\/([^/]+)\/analysis$/)
    if (m) return { page: 'analysis', id: m[1] }
    m = h.match(/^#\/session\/([^/]+)$/)
    if (m) return { page: 'session', id: m[1] }
    if (h === '#/analytics') return { page: 'analytics' }
    return { page: 'home' }
}

function navigate(hash) { location.hash = hash }

window.renderCurrentRoute = function() {
    const route = parseRoute()
    const main = document.getElementById('main-content')
    main.innerHTML = ''
    updateTopbar(route)
    // Always tear down live EventSource connections on a route change.
    // The new route's render will mount a fresh pane if it needs one
    // (the session-detail page does for active sessions). Without
    // this, a lingering SSE stream from a prior session page would
    // keep hitting the server in the background.
    _teardownAllLivePanes()
    if (route.page !== 'home') _stopHomePolling()
    // Stop any active session-polling loop when leaving session/
    // analysis routes so we do not keep re-rendering a page the
    // user has navigated away from. The session-polling helper
    // also self-stops if its target id no longer matches the route,
    // but stopping here handles the route-type change case cleanly.
    if (route.page !== 'session' && route.page !== 'analysis') {
        _stopSessionPolling()
    }
    switch (route.page) {
        case 'home': renderHome(); break
        case 'session': renderSession(route.id); break
        case 'analysis': renderAnalysis(route.id); break
        case 'analytics': renderAnalytics(); break
        default: renderHome()
    }
}

window.addEventListener('hashchange', window.renderCurrentRoute)

// ─── Topbar ───
function updateTopbar(route) {
    const left = document.getElementById('topbar-left')
    const titleEl = document.getElementById('topbar-title')
    const themeBtn = document.getElementById('theme-btn')
    const analyticsLink = document.getElementById('analytics-link')
    const opsContainer = document.getElementById('ops-dropdown-container')

    // Left area: always show logo (clickable to home), plus back button on sub-pages
    if (route.page === 'home') {
        left.innerHTML = `
            <a class="topbar-logo" href="#/" style="text-decoration:none">
                <span class="logo-mark">⬡</span>
                <span class="logo-text">${t('app.title')}</span>
            </a>`
        titleEl.textContent = ''
    } else {
        left.innerHTML = `
            <a class="topbar-back" href="#/">${t('nav.back')}</a>
            <a class="topbar-logo" href="#/" style="text-decoration:none">
                <span class="logo-mark">⬡</span>
                <span class="logo-text">${t('app.title')}</span>
            </a>`
        titleEl.textContent = route.id || ''
    }

    // Right area
    if (analyticsLink) analyticsLink.textContent = t('nav.analytics')
    if (themeBtn) themeBtn.textContent = document.documentElement.getAttribute('data-theme') === 'dark' ? '☀' : '☾'

    // Ops dropdown — only on session/analysis pages
    if (opsContainer) {
        opsContainer.style.display = (route.page === 'session' || route.page === 'analysis') ? '' : 'none'
    }

    // Populate ops menu labels
    const labels = { 'ops-plan': 'ops.view_plan', 'ops-analysis': 'ops.analysis', 'ops-preview-issue': 'ops.preview_issue', 'ops-export-md': 'ops.export_md', 'ops-export-pdf': 'ops.export_pdf', 'ops-cancel': 'ops.cancel' }
    for (const [id, key] of Object.entries(labels)) {
        const el = document.getElementById(id)
        if (el) el.textContent = t(key)
    }
}

// ─── Theme ───
function initTheme() {
    const saved = localStorage.getItem('humanize-viz-theme')
    const theme = (saved === 'dark' || saved === 'light') ? saved : 'dark'
    document.documentElement.setAttribute('data-theme', theme)
    if (saved !== theme) localStorage.setItem('humanize-viz-theme', theme)
}

function toggleTheme() {
    const cur = document.documentElement.getAttribute('data-theme')
    const next = cur === 'dark' ? 'light' : 'dark'
    document.documentElement.setAttribute('data-theme', next)
    localStorage.setItem('humanize-viz-theme', next)
    // Theme variables are declared via CSS custom properties keyed
    // on [data-theme], so switching the attribute is enough for the
    // paint to update on every route that styles via CSS vars
    // (home cards, session-detail pipeline + sidebar + log pane).
    // No DOM rebuild is needed there — pipeline zoom/pan, the open
    // flyout (if any), the live-log <pre> + EventSource, and the
    // log-panel collapse state all survive across toggles.
    const btn = document.getElementById('theme-btn')
    if (btn) btn.textContent = next === 'dark' ? '☀' : '☾'
    // Analytics is the one exception: charts read CSS vars via
    // getComputedStyle and bake the colors into SVG at render time,
    // so the on-screen charts don't repaint on attribute flip.
    // Re-render only that route; all other routes stay put.
    if (parseRoute().page === 'analytics') {
        renderAnalytics()
    }
}

// ─── API ───
async function api(url) {
    const opts = {}
    if (_authToken) {
        opts.headers = { 'Authorization': `Bearer ${_authToken}` }
    }
    const r = await fetch(url, opts)
    return r.ok ? r.json() : null
}

// Exported so actions.js fetches stay token-aware too. The main
// difference vs api() is that this returns the raw Response so
// callers can inspect status codes and error bodies.
window.authedFetch = function(url, init) {
    init = init || {}
    init.headers = Object.assign({}, init.headers || {})
    if (_authToken && !init.headers.Authorization) {
        init.headers.Authorization = `Bearer ${_authToken}`
    }
    return fetch(url, init)
}

function fmtDuration(m) {
    if (m == null) return '—'
    if (m < 60) return `${m} ${t('unit.min')}`
    return `${Math.floor(m/60)}h ${Math.round(m%60)}m`
}

function _esc(str) {
    const d = document.createElement('div')
    d.textContent = str || ''
    return d.innerHTML
}

// ─── Home ───
async function renderHome() {
    const main = document.getElementById('main-content')

    // Tear down any live-log panes from the previous render so we do
    // not leak EventSource connections across navigations.
    _teardownAllLivePanes()

    // Load projects, sessions, and the cross-session analytics strip
    // in parallel. Analytics is best-effort: if the endpoint fails we
    // still render the rest of the page and just drop the strip.
    const [projects, sessions, analytics] = await Promise.all([
        api('/api/projects').catch(() => []),
        api('/api/sessions').catch(() => []),
        api('/api/analytics').catch(() => null),
    ])

    // Project header (read-only). The legacy project switcher and
    // "+ Add" UI was removed in Round 5 (T10-frontend); the dashboard
    // is now CLI-fixed to one project at startup.
    const currentProject = (projects || [])[0] || {}
    const projectHeader = `
        <div class="project-bar">
            <div class="project-current">
                <span class="project-current-label">Project</span>
                <span class="project-current-path">${_esc(currentProject.name || '—')}</span>
                <span class="project-current-full" title="${_esc(currentProject.path || '')}">${_esc(currentProject.path || '')}</span>
            </div>
            <div style="font-size:0.72rem;color:var(--text-3)">
                CLI-fixed: run \`humanize monitor web --project &lt;path&gt;\` per project
            </div>
        </div>`

    const analyticsStrip = _renderHomeAnalyticsStrip(analytics)

    // The sessions region lives inside a stable wrapper so WS-push
    // refreshes can replace its innerHTML without touching
    // .project-bar. This removes the "fall back to renderHome()
    // when sections don't exist yet" branch that Codex flagged as a
    // full-page rebuild.
    const sessionsBody = _buildHomeSessionsHtml(sessions)
    main.innerHTML = `<div class="home">${projectHeader}${analyticsStrip}<div id="home-sessions">${sessionsBody}</div></div>`
}

// Cross-Session Analytics strip: four stat tiles (total sessions,
// avg rounds, completion rate, and a sparkline for rounds-per-day
// over the last 14 days). Mirrors the reference kit's home header
// block. Best-effort: drops silently when /api/analytics is empty.
function _renderHomeAnalyticsStrip(analytics) {
    if (!analytics || !analytics.overview) return ''
    const o = analytics.overview
    if ((o.total_sessions || 0) === 0) return ''
    const rpd = Array.isArray(o.rounds_per_day) ? o.rounds_per_day : []
    const windowDays = o.rounds_per_day_window || rpd.length || 14
    const sparkSvg = _renderSparkline(rpd)
    return `
        <div class="eyebrow-rule" style="margin-bottom:var(--space-3)">${t('analytics.title')}</div>
        <div class="analytics-grid" style="margin-bottom:var(--space-8)">
            <div class="stat"><div class="stat-num">${_esc(String(o.total_sessions))}</div><div class="stat-label">${t('analytics.total')}</div></div>
            <div class="stat"><div class="stat-num">${_esc(String(o.average_rounds))}</div><div class="stat-label">${t('analytics.avg_rounds')}</div></div>
            <div class="stat"><div class="stat-num">${_esc(String(o.completion_rate))}%</div><div class="stat-label">${t('analytics.completion')}</div></div>
            <div class="stat stat-chart">
                <div class="stat-label">${t('home.rounds_per_day')} (last ${windowDays}d)</div>
                ${sparkSvg}
            </div>
        </div>`
}

// Compact inline SVG sparkline. Draws a filled area + polyline +
// trailing dot. Zero-data input renders an empty but valid SVG so
// layout stays stable.
function _renderSparkline(values) {
    const W = 180, H = 42, PAD = 2
    const n = values.length
    if (n === 0) return `<svg class="spark" viewBox="0 0 ${W} ${H}"></svg>`
    const peak = Math.max(1, ...values.map(v => Number(v) || 0))
    const step = n > 1 ? (W - PAD * 2) / (n - 1) : 0
    const pts = values.map((v, i) => {
        const x = PAD + i * step
        const y = H - PAD - ((Number(v) || 0) / peak) * (H - PAD * 2)
        return { x, y }
    })
    const poly = pts.map(p => `${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(' ')
    const areaPts = [
        `${PAD},${H - PAD}`,
        ...pts.map(p => `${p.x.toFixed(1)},${p.y.toFixed(1)}`),
        `${PAD + (n - 1) * step},${H - PAD}`,
    ].join(' ')
    const last = pts[pts.length - 1]
    return `
        <svg class="spark" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none">
            <polygon class="spark-fill" points="${areaPts}"></polygon>
            <polyline class="spark-line" points="${poly}"></polyline>
            <circle class="spark-dot" cx="${last.x.toFixed(1)}" cy="${last.y.toFixed(1)}" r="2.2"></circle>
        </svg>`
}

// Builds the HTML body that goes inside #home-sessions. Covers all
// three cases: empty, active-only, completed-only, both. Shared by
// the initial renderHome() and the incremental _refreshHomeCards().
//
// The section label + list container elements carry the same
// `data-home-section` / `data-home-section-label` attributes that
// _applyHomeSection queries against. Without those attributes the
// first WS refresh would not find the initial render's container
// and would create a second one, showing two Active sections on
// screen for a single running loop — the duplicate-card bug.
function _buildHomeSessionsHtml(sessions) {
    if (!sessions || sessions.length === 0) {
        return `<div class="empty"><div class="empty-icon">⬡</div><div class="empty-msg">${t('home.empty')}</div><div class="empty-hint">${t('home.empty.hint')}</div></div>`
    }
    const active = sessions.filter(s => ['active','analyzing','finalizing'].includes(s.status))
    const finished = sessions.filter(s => !['active','analyzing','finalizing'].includes(s.status))
    let html = ''
    // Reference kit wraps each row of cards in a <section> with an
    // uppercase "eyebrow-rule" label and a .session-grid container
    // (auto-fit columns at a generous min-width). Both Active and
    // Completed now use the same skin — the status badge + pulse
    // dot inside each card carries the "running" signal instead.
    // The inline diff-updater (_applyHomeSection) creates label +
    // container pairs directly under #home-sessions when a section
    // first materializes; keeping the initial render's shape the
    // same (no <section> wrapper) avoids layout drift between the
    // initial render and the WS-driven lazy creation.
    if (active.length) {
        html += `<div class="eyebrow-rule" data-home-section-label="active">${t('home.active')}</div>`
        html += `<div class="session-grid" data-home-section="active">${active.map(activeSessionPane).join('')}</div>`
    }
    if (finished.length) {
        html += `<div class="eyebrow-rule completed" data-home-section-label="completed">${t('home.completed')}</div>`
        html += `<div class="session-grid" data-home-section="completed">${finished.map(sessionCard).join('')}</div>`
    }
    return html
}

function _latestActiveLog(session) {
    // session.cache_logs is the deterministic list emitted by
    // viz/server/parser.py:cache_logs_for_session — sorted by
    // (round, tool, role) ascending. Reproduce the CLI's
    // `humanize monitor rlcr` Log: line by picking the codex-run log
    // for the highest round, falling back through the other
    // tool/role combinations. Without this the naive cache_logs[-1]
    // could land on `gemini-review` or `codex-review` for the same
    // round, which is the wrong file — the user expects the primary
    // implementation/review stream, not a secondary one.
    const logs = session.cache_logs || []
    if (logs.length === 0) return null
    let maxRound = -1
    for (const l of logs) if (l.round > maxRound) maxRound = l.round
    const preference = [
        ['codex', 'run'],
        ['codex', 'review'],
        ['gemini', 'run'],
        ['gemini', 'review'],
    ]
    for (const [tool, role] of preference) {
        const match = logs.find(l => l.round === maxRound && l.tool === tool && l.role === role)
        if (match) return match
    }
    // No codex/gemini match at the top round — surface anything we
    // have so the pane is not empty (defensive; real sessions always
    // carry at least one of the above).
    return logs.filter(l => l.round === maxRound).pop() || logs[logs.length - 1]
}

// Active pane on the home page: just the plain sessionCard — the
// live monitor log stream lives on the session-detail page (below
// the pipeline canvas), not here.
function activeSessionPane(s) {
    return sessionCard(s)
}

// ─── Live log panes (T6) ───
//
// Each active session gets its own EventSource talking to
// /api/sessions/<sid>/logs/<basename>. Multiple panes coexist on the
// home page; navigating away tears them all down so we do not leak
// open connections.
function _mountLiveLogPane(sessionId, logEntry) {
    const pane = document.getElementById(`live-log-pane-${sessionId}`)
    const status = document.getElementById(`live-log-status-${sessionId}`)
    if (!pane) return

    const url = _withToken(`/api/sessions/${encodeURIComponent(sessionId)}/logs/${encodeURIComponent(logEntry.basename)}`)
    const es = new EventSource(url)

    const _utf8Decoder = new TextDecoder('utf-8', { fatal: false })
    let bytesSeen = 0
    function appendBytes(b64, { flush = false } = {}) {
        try {
            // atob returns a Latin-1 byte-string; convert to a real
            // byte array and decode as UTF-8 so non-ASCII log output
            // (CJK text, emoji, smart quotes) renders correctly
            // instead of as mojibake.
            //
            // `{ stream: true }` keeps the decoder's internal buffer
            // alive across calls, so a multibyte UTF-8 sequence
            // split at the 64 KiB SSE chunk boundary is reassembled
            // on the next event instead of being emitted as U+FFFD
            // replacement characters. Callers pass `flush: true`
            // when the stream is known to be complete (resync
            // reason=truncated/rotated/recreated/overflow, eof) so
            // the decoder's trailing buffer is finalised and not
            // accidentally prefixed to the next snapshot.
            const binStr = atob(b64)
            const bytes = new Uint8Array(binStr.length)
            for (let i = 0; i < binStr.length; i++) bytes[i] = binStr.charCodeAt(i)
            const text = _utf8Decoder.decode(bytes, { stream: !flush })
            pane.textContent += text
            bytesSeen += bytes.length
            // Cap pane size to avoid runaway memory on long sessions.
            const MAX_PANE_BYTES = 256 * 1024
            if (pane.textContent.length > MAX_PANE_BYTES) {
                pane.textContent = '... (truncated, showing tail)\n' +
                    pane.textContent.slice(-MAX_PANE_BYTES + 64)
            }
            pane.scrollTop = pane.scrollHeight
        } catch (_) {}
    }

    function setStatus(text, kind) {
        if (!status) return
        status.textContent = text
        status.className = 'live-log-status' + (kind ? ` live-log-status-${kind}` : '')
    }

    es.addEventListener('snapshot', (e) => {
        try {
            const data = JSON.parse(e.data)
            if (data.offset === 0) pane.textContent = ''
            appendBytes(data.bytes_b64)
            setStatus(`live (${bytesSeen}B)`, 'ok')
        } catch (_) {}
    })

    es.addEventListener('append', (e) => {
        try {
            const data = JSON.parse(e.data)
            appendBytes(data.bytes_b64)
            setStatus(`live (${bytesSeen}B)`, 'ok')
        } catch (_) {}
    })

    es.addEventListener('resync', (e) => {
        try {
            const data = JSON.parse(e.data)
            setStatus(`resync: ${data.reason}`, 'warn')
            if (data.reason === 'truncated' || data.reason === 'rotated' ||
                data.reason === 'recreated' || data.reason === 'overflow') {
                // Stream is discontinuous from here: finalise the
                // decoder so any trailing buffered bytes from the
                // previous file don't bleed into the fresh content
                // that follows.
                try { _utf8Decoder.decode(new Uint8Array(0)) } catch (_) {}
                pane.textContent = ''
                bytesSeen = 0
            }
        } catch (_) {}
    })

    es.addEventListener('eof', () => {
        setStatus('eof', 'eof')
        es.close()
        _liveLogPanes.delete(sessionId)
        // Flush the decoder so a trailing incomplete multibyte
        // sequence (if any) is rendered as U+FFFD rather than
        // silently dropped.
        try { _utf8Decoder.decode(new Uint8Array(0)) } catch (_) {}
        // The session just transitioned to a terminal status. The
        // sidebar/pipeline are snapshots and will show the new status
        // when the user navigates away and back or reloads; no
        // auto-refresh is triggered here on purpose (avoids the whole
        // page flashing when a session finishes).
    })

    es.onerror = () => {
        setStatus('disconnected (will retry)', 'warn')
        // EventSource auto-reconnects with exponential backoff; we
        // do nothing here. On real disconnect the browser sends
        // Last-Event-Id so the server replays missed events.
    }

    _liveLogPanes.set(sessionId, { eventSource: es, element: pane, basename: logEntry.basename })
}

function _teardownAllLivePanes() {
    for (const [, entry] of _liveLogPanes) {
        try { entry.eventSource.close() } catch (_) {}
    }
    _liveLogPanes.clear()
}

function sessionCard(s) {
    const plan = s.plan_file ? s.plan_file.split('/').pop() : '—'
    const started = s.started_at ? new Date(s.started_at).toLocaleString() : '—'
    const acPct = s.ac_total > 0 ? Math.round(s.ac_done / s.ac_total * 100) : 0
    const verdict = s.last_verdict || 'unknown'
    const statusLabel = t('status.' + s.status) || s.status
    const isActive = ['active', 'analyzing', 'finalizing'].includes(s.status)
    const idShort = (s.id || '').slice(0, 19)
    const duration = fmtDuration(s.duration_minutes)

    // Reference-kit skin: condensed head (round + id + status badge
    // with pulse dot when in-flight) → 2×2 mono meta grid → AC
    // progress bar → mono foot strip with timestamps and task count.
    return `
        <div class="session-card" data-session-id="${_esc(s.id)}" onclick="navigate('#/session/${s.id}')">
            <div class="session-head">
                <div class="session-head-left">
                    <span class="session-round">${t('card.round')} ${s.current_round}/${s.max_iterations}</span>
                    <span class="session-id" title="${_esc(s.id)}">${_esc(idShort)}</span>
                </div>
                <span class="badge badge-${s.status}">
                    ${isActive ? '<span class="badge-dot"></span>' : ''}${_esc(statusLabel)}
                </span>
            </div>
            <div class="session-meta">
                <div><div class="k">${t('card.plan')}</div><div class="v" title="${_esc(plan)}">${esc(plan)}</div></div>
                <div><div class="k">${t('card.branch')}</div><div class="v" title="${_esc(s.start_branch || '')}">${esc(s.start_branch || '—')}</div></div>
                <div><div class="k">${t('card.verdict')}</div><div class="v verdict-${_esc(verdict)}">${_esc(verdict)}</div></div>
                <div><div class="k">${t('card.ac')}</div><div class="v">${s.ac_done}/${s.ac_total}</div></div>
            </div>
            <div class="session-ac" title="Acceptance criteria: ${s.ac_done}/${s.ac_total} (${acPct}%)">
                <div class="ac-bar"><div class="ac-bar-fill" style="width:${acPct}%"></div></div>
            </div>
            <div class="session-foot">
                <span>${_esc(started)} · ${_esc(duration)}</span>
                <span>${t('detail.tasks')}: ${s.tasks_done}/${s.tasks_total}</span>
            </div>
        </div>`
}

// ─── Session Detail ───
async function renderSession(sessionId) {
    const main = document.getElementById('main-content')
    const session = await api(`/api/sessions/${sessionId}`)
    if (!session) {
        main.innerHTML = `<div class="page"><div class="empty"><div class="empty-msg">${t('detail.not_found')}</div></div></div>`
        return
    }

    // Auto-refresh disabled: the SSE live-log pane at the bottom of
    // the page streams bytes into its own <pre> without any page
    // re-render, which is the only surface that truly needs to be
    // live. Pipeline / sidebar / goal-bar are snapshots; to refresh
    // them the user navigates away and back or reloads the page.

    // Build the detail-layout skeleton only on first entry. On
    // subsequent re-renders for the same session id we reuse the
    // existing DOM so the bottom live-log pane is not destroyed.
    let layout = main.querySelector(`.detail-layout[data-session-id="${CSS.escape(sessionId)}"]`)
    if (!layout) {
        _teardownAllLivePanes()
        main.innerHTML = `
            <div class="detail-layout" data-session-id="${_esc(sessionId)}">
                <div class="graph-area">
                    <div class="pipeline-container" id="pipeline-root"></div>
                </div>
                <div class="session-sidebar" id="session-sidebar"></div>
                <div class="session-log" id="session-log-container"></div>
                <div class="goal-bar" id="goal-bar"></div>
            </div>`
        layout = main.querySelector('.detail-layout')
    }
    _applyDetailLayoutMode(session)

    renderPipeline(document.getElementById('pipeline-root'), session)
    renderSessionSidebar(session)
    renderGoalBar(session)
    _ensureSessionLogPane(session)
    window._currentSession = session

    const cancelBtn = document.getElementById('ops-cancel')
    // Mirror the backend's _CANCELLABLE_STATUSES (Round 8): the cancel
    // helper supports active, analyzing, and finalizing sessions, so
    // the UI must expose the button in all three phases. Round 10
    // previously hid the button outside of 'active', which made
    // stuck analyze/finalize sessions uncancellable from the UI.
    const CANCELLABLE_STATUSES = ['active', 'analyzing', 'finalizing']
    if (cancelBtn) cancelBtn.style.display = CANCELLABLE_STATUSES.includes(session.status) ? '' : 'none'
}

// Incremental re-render used by WS pushes and the 5-second polling
// loop. Re-fetches the session, re-populates pipeline + sidebar +
// goal-bar, and leaves the bottom live-log pane (and its
// EventSource) untouched so the streaming log does not reset.
// Falls back to a full renderSession() when the layout skeleton
// doesn't match (e.g. first entry after a route change).
async function _refreshSession(sessionId) {
    const main = document.getElementById('main-content')
    const layout = main && main.querySelector(`.detail-layout[data-session-id="${CSS.escape(sessionId)}"]`)
    if (!layout) {
        renderSession(sessionId)
        return
    }
    const session = await api(`/api/sessions/${sessionId}`)
    if (!session) return
    _applyDetailLayoutMode(session)
    renderPipeline(document.getElementById('pipeline-root'), session)
    renderSessionSidebar(session)
    renderGoalBar(session)
    _ensureSessionLogPane(session)
    window._currentSession = session
    const cancelBtn = document.getElementById('ops-cancel')
    const CANCELLABLE = ['active', 'analyzing', 'finalizing']
    if (cancelBtn) cancelBtn.style.display = CANCELLABLE.includes(session.status) ? '' : 'none'
}

// Toggles the detail-layout's "has-log" modifier so the grid grows
// a third row for the live-log panel only for active sessions.
// Completed / cancelled sessions keep the original two-row layout
// (graph + goal-bar), matching the previous look.
function _applyDetailLayoutMode(session) {
    const layout = document.querySelector('.detail-layout')
    if (!layout) return
    const hasLive = ['active', 'analyzing', 'finalizing'].includes(session.status)
                  && Array.isArray(session.cache_logs) && session.cache_logs.length > 0
    layout.classList.toggle('has-log', !!hasLive)
}

// Creates the live-log pane inside #session-log-container exactly
// once per session entry. If the session is not active or has no
// cache log yet, the container is emptied and any existing pane is
// torn down. Idempotent when called repeatedly with the same
// (sessionId, basename) pair — the existing EventSource keeps
// streaming into the same <pre>.
function _ensureSessionLogPane(session) {
    const container = document.getElementById('session-log-container')
    if (!container) return
    const active = ['active', 'analyzing', 'finalizing'].includes(session.status)
    const latest = _latestActiveLog(session)
    if (!active || !latest) {
        // No live log needed; tear down any prior pane.
        const prev = _liveLogPanes.get(session.id)
        if (prev) {
            try { prev.eventSource.close() } catch (_) {}
            _liveLogPanes.delete(session.id)
        }
        container.innerHTML = ''
        return
    }
    const prev = _liveLogPanes.get(session.id)
    if (prev && prev.basename === latest.basename && container.contains(prev.element)) {
        // Same log file is already streaming; nothing to do.
        return
    }
    // Either no pane yet, or the latest cache log rolled to a newer
    // round — rebuild only this subtree (the container), leaving
    // the rest of the detail layout intact. Preserve the toggle
    // state (collapsed / normal / expanded) across the basename
    // switch so a user who expanded the log is not bounced back to
    // the default height every time a new round starts.
    const layout = document.querySelector('.detail-layout.has-log')
    const priorState = !layout
        ? 'normal'
        : layout.classList.contains('log-collapsed') ? 'collapsed'
        : layout.classList.contains('log-expanded')  ? 'expanded'
        : 'normal'
    if (prev) {
        try { prev.eventSource.close() } catch (_) {}
        _liveLogPanes.delete(session.id)
    }
    container.innerHTML = `
        <div class="live-log-header">
            <span class="live-log-badge">LIVE</span>
            <span class="live-log-name" title="${_esc(latest.path || '')}">${_esc(latest.basename)}</span>
            <span class="live-log-status" id="live-log-status-${_esc(session.id)}">connecting…</span>
            <span class="live-log-toggle">
                <button class="live-log-btn js-log-expand"   type="button" title="Expand to fill canvas"       onclick="toggleSessionLog('expanded')">▴</button>
                <button class="live-log-btn js-log-normal"   type="button" title="Restore default height"     onclick="toggleSessionLog('normal')">▭</button>
                <button class="live-log-btn js-log-collapse" type="button" title="Collapse (header only)"     onclick="toggleSessionLog('collapsed')">▾</button>
            </span>
        </div>
        <pre class="live-log-pane" id="live-log-pane-${_esc(session.id)}"></pre>`
    _mountLiveLogPane(session.id, latest)
    // Re-apply the prior toggle state so the active button lights up
    // and the grid row keeps whichever height the user picked.
    window.toggleSessionLog(priorState)
}

// Three-state collapse/expand control for the session-detail log
// panel. 'normal' is the default 260px row, 'collapsed' shrinks to
// the header only (so the pipeline canvas sees more vertical space),
// and 'expanded' grows the log to cover most of the canvas for
// reading long bursts. The state lives as a CSS class on
// .detail-layout so the grid-template-rows swap happens in one place.
window.toggleSessionLog = function(state) {
    const layout = document.querySelector('.detail-layout.has-log')
    if (!layout) return
    layout.classList.remove('log-collapsed', 'log-normal', 'log-expanded')
    if (state === 'collapsed') layout.classList.add('log-collapsed')
    else if (state === 'expanded') layout.classList.add('log-expanded')
    // 'normal' = no modifier class. Reflect the new state on the
    // toggle buttons (hide the one matching the current state).
    const buttons = layout.querySelectorAll('.live-log-btn')
    buttons.forEach(b => { b.classList.remove('is-active') })
    const cls = state === 'collapsed' ? '.js-log-collapse'
              : state === 'expanded'  ? '.js-log-expand'
              : '.js-log-normal'
    const activeBtn = layout.querySelector(cls)
    if (activeBtn) activeBtn.classList.add('is-active')
}

// Used by openFlyout/closeFlyout in pipeline.js: when the user opens
// a node's details, auto-collapse the log so the modal (and the
// underlying pipeline canvas) have more room. The prior state is
// remembered and restored when the flyout is dismissed.
let _savedLogState = null
window.autoCollapseSessionLog = function() {
    const layout = document.querySelector('.detail-layout.has-log')
    if (!layout) return
    _savedLogState = layout.classList.contains('log-collapsed') ? 'collapsed'
                   : layout.classList.contains('log-expanded')  ? 'expanded'
                   : 'normal'
    window.toggleSessionLog('collapsed')
}
window.restoreSessionLog = function() {
    if (_savedLogState == null) return
    const prev = _savedLogState
    _savedLogState = null
    window.toggleSessionLog(prev)
}

function renderSessionSidebar(s) {
    const sidebar = document.getElementById('session-sidebar')
    if (!sidebar) return

    const acTotal = s.ac_total || 0
    const acDone = s.ac_done || 0
    const acPct = acTotal > 0 ? Math.round(acDone / acTotal * 100) : 0

    const vCounts = { advanced: 0, stalled: 0, regressed: 0 }
    let reviewedRounds = 0
    for (const r of (s.rounds || [])) {
        if (r.review_result && selectLang(r.review_result)) {
            const v = r.verdict
            if (v in vCounts) vCounts[v]++
            reviewedRounds++
        }
    }

    const verdictBars = Object.entries(vCounts).map(([v, count]) => {
        const pct = reviewedRounds > 0 ? Math.round(count / reviewedRounds * 100) : 0
        return `<div class="sidebar-verdict-row">
            <span style="width:70px;color:var(--verdict-${v})">${v}</span>
            <div class="sidebar-verdict-bar"><div class="sidebar-verdict-fill" style="width:${pct}%;background:var(--verdict-${v})"></div></div>
            <span style="width:28px;text-align:right;color:var(--text-2);font-family:var(--font-mono);font-size:0.75rem">${count}</span>
        </div>`
    }).join('')

    const acs = s.goal_tracker?.acceptance_criteria || []
    const acListHtml = acs.map(ac => {
        const icon = ac.status === 'completed' ? '✓' : ac.status === 'in_progress' ? '◉' : '○'
        const color = ac.status === 'completed' ? 'var(--verdict-advanced)' : ac.status === 'in_progress' ? 'var(--verdict-active)' : 'var(--text-3)'
        return `<div class="sidebar-ac-item">
            <span class="sidebar-ac-icon" style="color:${color}">${icon}</span>
            <span class="sidebar-ac-text">${_esc(ac.id)}: ${_esc(ac.description?.slice(0, 60) || '')}</span>
        </div>`
    }).join('')

    const plan = s.plan_file ? s.plan_file.split('/').pop() : '—'
    const started = s.started_at ? new Date(s.started_at).toLocaleString() : '—'

    sidebar.innerHTML = `
        <div class="sidebar-section">
            <div class="sidebar-title">Overview</div>
            <div class="sidebar-stat-grid">
                <div class="sidebar-stat"><div class="sidebar-stat-num">${s.current_round}</div><div class="sidebar-stat-label">Rounds</div></div>
                <div class="sidebar-stat"><div class="sidebar-stat-num">${acPct}%</div><div class="sidebar-stat-label">${t('card.ac')}</div></div>
                <div class="sidebar-stat"><div class="sidebar-stat-num">${s.tasks_done || 0}</div><div class="sidebar-stat-label">Done</div></div>
                <div class="sidebar-stat"><div class="sidebar-stat-num">${s.tasks_total || 0}</div><div class="sidebar-stat-label">Total</div></div>
            </div>
        </div>
        <div class="sidebar-section">
            <div class="sidebar-title">${t('card.verdict')} Distribution</div>
            <div class="sidebar-verdict-list">${verdictBars}</div>
        </div>
        <div class="sidebar-section">
            <div class="sidebar-title">Session Info</div>
            <div class="sidebar-meta">
                <div class="sidebar-meta-row"><span class="sidebar-meta-key">Status</span><span class="badge badge-${s.status}">${t('status.' + s.status)}</span></div>
                <div class="sidebar-meta-row"><span class="sidebar-meta-key">${t('card.plan')}</span><span class="sidebar-meta-val">${_esc(plan)}</span></div>
                <div class="sidebar-meta-row"><span class="sidebar-meta-key">${t('card.branch')}</span><span class="sidebar-meta-val">${_esc(s.start_branch || '—')}</span></div>
                <div class="sidebar-meta-row"><span class="sidebar-meta-key">${t('card.started')}</span><span class="sidebar-meta-val" style="font-size:0.72rem">${started}</span></div>
                <div class="sidebar-meta-row"><span class="sidebar-meta-key">${t('card.duration')}</span><span class="sidebar-meta-val">${fmtDuration(s.duration_minutes)}</span></div>
                <div class="sidebar-meta-row"><span class="sidebar-meta-key">Max Iter</span><span class="sidebar-meta-val">${s.max_iterations}</span></div>
                <div class="sidebar-meta-row"><span class="sidebar-meta-key">Codex</span><span class="sidebar-meta-val">${_esc(s.codex_model || '—')}</span></div>
            </div>
        </div>
        ${acs.length > 0 ? `
        <div class="sidebar-section">
            <div class="sidebar-title">${t('card.ac')} Checklist</div>
            <div class="sidebar-ac-list">${acListHtml}</div>
            <div class="progress-bar" style="margin-top:var(--space-3)"><div class="progress-fill" style="width:${acPct}%"></div></div>
            <div style="font-size:0.72rem;color:var(--text-3);margin-top:var(--space-1);text-align:right">${acDone}/${acTotal}</div>
        </div>` : ''}

        <div class="sidebar-section">
            <div class="sidebar-title">Upstream Feedback</div>
            <div style="font-size:0.8rem;color:var(--text-2);margin-bottom:var(--space-3)">
                Submit a sanitized methodology report to <strong style="color:var(--text-1)">PolyArch/humanize</strong> to help improve the RLCR process.
            </div>
            <div id="sidebar-gh-actions">
                <button class="btn" style="width:100%;justify-content:center;margin-bottom:var(--space-2)" onclick="sidebarGenerateAndPreview('${s.id}')">
                    <span style="opacity:0.7">👁</span> Preview Issue
                </button>
                <button class="btn btn-primary" style="width:100%;justify-content:center" onclick="sidebarGenerateAndSend('${s.id}')">
                    <span style="opacity:0.8">↗</span> Submit to GitHub
                </button>
            </div>
            <div id="sidebar-gh-result" style="margin-top:var(--space-3)"></div>
        </div>`
}

function renderGoalBar(session) {
    const bar = document.getElementById('goal-bar')
    if (!bar || !session.goal_tracker) return
    const acs = session.goal_tracker.acceptance_criteria || []
    bar.innerHTML = acs.map(ac => {
        const cls = ac.status === 'completed' ? 'done' : ac.status === 'in_progress' ? 'wip' : ''
        const icon = ac.status === 'completed' ? '✓' : ac.status === 'in_progress' ? '◉' : '○'
        return `<span class="ac-pill ${cls}">${icon} ${ac.id}</span>`
    }).join('')
}

// ─── Analysis ───
async function renderAnalysis(sessionId) {
    const main = document.getElementById('main-content')
    const session = await api(`/api/sessions/${sessionId}`)
    if (!session) {
        main.innerHTML = `<div class="page"><div class="empty"><div class="empty-msg">${t('detail.not_found')}</div></div></div>`
        return
    }

    // Auto-refresh disabled per user request; reload the page to
    // pick up a newly generated methodology report.

    const report = selectLang(session.methodology_report)
    const hasReport = !!report

    let sanitizedHtml = `<div class="empty"><div class="empty-msg">${t('analysis.no_report')}</div></div>`
    if (hasReport) {
        const sanitized = await api(`/api/sessions/${sessionId}/sanitized-issue`)
        if (sanitized) {
            const w = sanitized.warnings || {}
            const hasW = sanitized.requires_review || Object.keys(w).length > 0
            const warnBanner = hasW ? `<div class="warning-banner">${t('analysis.review_warning')}<br>${Object.entries(w).map(([c,n]) => `<span>• ${esc(c)}: ${n}</span>`).join(' ')}</div>` : ''
            const btns = hasW ? '' : `<div style="display:flex;gap:var(--space-3);margin-top:var(--space-4)"><button class="btn btn-primary" onclick="previewGitHubIssue('${sessionId}')">${t('analysis.preview')}</button><button class="btn" onclick="sendGitHubIssue('${sessionId}')">${t('analysis.send')}</button></div>`
            sanitizedHtml = `${warnBanner}<div class="md">${safeMd(sanitized.body)}</div><div class="gh-section"><div style="font-size:0.85rem;color:var(--text-2);margin-bottom:var(--space-3)"><strong>${t('analysis.gh_repo')}:</strong> PolyArch/humanize</div>${btns}<div id="gh-result"></div></div>`
        }
    }

    main.innerHTML = `
        <div class="page">
            <div class="tabs">
                <div class="tab active" data-tab="report">${t('analysis.report_tab')}</div>
                <div class="tab" data-tab="summary">${t('analysis.summary_tab')}</div>
            </div>
            <div class="tab-content" id="tab-report" style="display:block">
                ${hasReport ? `<div class="md">${safeMd(report)}</div>` : `<div class="empty"><div class="empty-msg">${t('analysis.no_report')}</div></div>`}
            </div>
            <div class="tab-content" id="tab-summary" style="display:none">${sanitizedHtml}</div>
        </div>`

    document.querySelectorAll('.tab').forEach(tab => {
        tab.addEventListener('click', () => {
            document.querySelectorAll('.tab').forEach(el => el.classList.remove('active'))
            document.querySelectorAll('.tab-content').forEach(el => el.style.display = 'none')
            tab.classList.add('active')
            document.getElementById('tab-' + tab.dataset.tab).style.display = 'block'
        })
    })
    window._currentSession = session
}

// ─── Analytics ───
async function renderAnalytics() {
    const main = document.getElementById('main-content')
    const data = await api('/api/analytics')
    if (!data) {
        main.innerHTML = `<div class="page"><div class="empty"><div class="empty-msg">${t('analytics.no_data')}</div></div></div>`
        return
    }

    const o = data.overview

    main.innerHTML = `
        <div class="page">
            <h2 style="margin-bottom:var(--space-6)">${t('analytics.title')}</h2>
            <div class="stats-row">
                <div class="stat-card"><div class="stat-number">${o.total_sessions}</div><div class="stat-label">${t('analytics.total')}</div></div>
                <div class="stat-card"><div class="stat-number">${o.average_rounds}</div><div class="stat-label">${t('analytics.avg_rounds')}</div></div>
                <div class="stat-card"><div class="stat-number">${o.completion_rate}%</div><div class="stat-label">${t('analytics.completion')}</div></div>
                <div class="stat-card"><div class="stat-number">${o.total_bitlessons}</div><div class="stat-label">${t('analytics.bitlessons')}</div></div>
            </div>

            <div id="timeline-root"></div>

            <h3 style="margin-bottom:var(--space-4)">${t('analytics.comparison')}</h3>
            <div id="cmp-root"></div>
        </div>`

    // Chart.js panels (rounds per session, duration, verdict
    // distribution, P-issues, first-COMPLETE, BitLesson growth) were
    // removed per user request — the four summary tiles + timeline +
    // session comparison table cover the analytics needs without the
    // extra chart stack.
    buildCmpTable(data.session_stats)

    // Load timeline asynchronously (needs full session data, can be slow)
    if (data.session_stats && data.session_stats.length > 0) {
        loadTimeline(data.session_stats)
    }
}

async function loadTimeline(sessionStats) {
    const root = document.getElementById('timeline-root')
    if (!root) return

    try {
        const sessions = await Promise.all(
            sessionStats.map(s => api(`/api/sessions/${s.session_id}`).catch(() => null))
        )
        const valid = sessions.filter(Boolean)
        if (valid.length === 0) return

        const rows = valid.map(s => {
            const dots = (s.rounds || []).map(r => {
                const v = r.verdict || 'unknown'
                return `<span class="tl-dot" style="background:var(--verdict-${v})" title="R${r.number}: ${v}"></span>`
            }).join('')
            return `<div class="tl-row">
                <a class="tl-label" onclick="navigate('#/session/${s.id}')">${s.id.slice(5, 16).replace('_', ' ')}</a>
                <div class="tl-dots">${dots}</div>
                <span class="badge badge-${s.status}" style="font-size:0.6rem">${t('status.' + s.status)}</span>
            </div>`
        }).join('')

        root.innerHTML = `
            <div class="section-label">Round Verdict Timeline</div>
            <div class="chart-panel" style="margin-bottom:var(--space-8)">
                <div class="tl-container">${rows}</div>
                <div class="tl-legend">
                    <span><span class="tl-dot" style="background:var(--verdict-advanced)"></span> advanced</span>
                    <span><span class="tl-dot" style="background:var(--verdict-stalled)"></span> stalled</span>
                    <span><span class="tl-dot" style="background:var(--verdict-regressed)"></span> regressed</span>
                    <span><span class="tl-dot" style="background:var(--verdict-complete)"></span> complete</span>
                    <span><span class="tl-dot" style="background:var(--verdict-unknown)"></span> unknown</span>
                </div>
            </div>`
    } catch (e) {
        console.error('[analytics] timeline failed:', e)
    }
}

function buildCmpTable(stats) {
    const root = document.getElementById('cmp-root')
    if (!root || !stats || !stats.length) return

    const sorted = [...stats].sort((a, b) => {
        let va, vb
        switch (_sortCol) {
            case 'rounds': va = a.rounds; vb = b.rounds; break
            case 'duration': va = a.avg_duration_minutes || 0; vb = b.avg_duration_minutes || 0; break
            case 'verdict': va = (a.verdict_breakdown||{}).advanced||0; vb = (b.verdict_breakdown||{}).advanced||0; break
            case 'rework': va = a.rework_count; vb = b.rework_count; break
            case 'ac': va = a.ac_completion_rate; vb = b.ac_completion_rate; break
            default: va = a.session_id; vb = b.session_id
        }
        return _sortAsc ? (va < vb ? -1 : va > vb ? 1 : 0) : (va > vb ? -1 : va < vb ? 1 : 0)
    })

    const arr = c => _sortCol === c ? (_sortAsc ? ' ▲' : ' ▼') : ''
    const cols = [
        ['session_id', 'Session'],
        [null, 'Status'],
        ['rounds', 'Rounds'],
        ['duration', 'Duration'],
        ['verdict', 'Verdict (A/S/R)'],
        ['rework', 'Rework'],
        ['ac', 'AC %'],
    ]

    let html = `<table class="cmp-table"><thead><tr>${cols.map(([k, label]) =>
        k ? `<th onclick="sortCmp('${k}')">${label}${arr(k)}</th>` : `<th>${label}</th>`
    ).join('')}</tr></thead><tbody>`

    for (const s of sorted) {
        const vb = s.verdict_breakdown || {}
        // Escape every attacker-reachable value before splicing into
        // the innerHTML template. The backend filter on /api/analytics
        // already rejects session ids outside `[A-Za-z0-9_.-]+`, so in
        // practice the escape here is defense-in-depth: a future
        // producer that forgets to apply the filter should still be
        // safely rendered rather than breaking out of the inline
        // onclick / cell HTML (the exact regression Codex Round 23
        // flagged). `s.status` is trusted (enum from parser.py) but
        // piped through _esc too for consistency.
        const idEsc = _esc(s.session_id)
        html += `<tr>
            <td><a class="cmp-nav" data-session-id="${idEsc}" style="cursor:pointer">${idEsc}</a></td>
            <td><span class="badge badge-${_esc(s.status)}">${_esc(t('status.' + s.status))}</span></td>
            <td>${_esc(String(s.rounds))}</td>
            <td>${s.avg_duration_minutes != null ? _esc(String(s.avg_duration_minutes)) + ' min' : '—'}</td>
            <td>${_esc(String(vb.advanced||0))}/${_esc(String(vb.stalled||0))}/${_esc(String(vb.regressed||0))}</td>
            <td>${_esc(String(s.rework_count))}</td>
            <td>${_esc(String(s.ac_completion_rate))}%</td>
        </tr>`
    }
    html += '</tbody></table>'
    root.innerHTML = html
    // Bind navigation via data-attribute + delegated listener so the
    // session id never flows through an inline JS string literal.
    // Even if a future backend regression lets through a session id
    // containing quote/script characters, the value only ever touches
    // dataset (DOM-level string, never re-parsed as JS) and window
    // navigation, neither of which evaluates markup.
    root.querySelectorAll('a.cmp-nav').forEach(a => {
        a.addEventListener('click', () => navigate('#/session/' + a.dataset.sessionId))
    })
    window._cmpStats = stats
}

function sortCmp(col) {
    if (_sortCol === col) _sortAsc = !_sortAsc
    else { _sortCol = col; _sortAsc = true }
    if (window._cmpStats) buildCmpTable(window._cmpStats)
}

// ─── Init ───
document.addEventListener('DOMContentLoaded', () => {
    initTheme()
    connectWebSocket()
    // In remote mode WS is disabled server-side, so kick a slow
    // polling loop that drives the same targeted-refresh path. In
    // localhost mode this is a no-op because _startRemotePolling
    // gates on _isRemoteMode.
    _startRemotePolling()
    window.renderCurrentRoute()
})
