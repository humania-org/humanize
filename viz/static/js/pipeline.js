/* Pipeline — snake-path node layout with SVG connectors + zoom/pan + flyout detail */

const PL = {
    COLS: 4,
    NODE_W: 230,
    NODE_H: 68,
    GAP_X: 52,
    GAP_Y: 48,
    TURN_H: 56,
    PADDING: 40,
}

let _scale = 1, _tx = 0, _ty = 0
let _dragging = false, _dragStartX = 0, _dragStartY = 0, _dragTx = 0, _dragTy = 0

// Window-level drag listeners are installed exactly once across the
// lifetime of the page. renderPipeline() is invoked on every SSE-
// driven session refresh, so registering window listeners per render
// would leak a growing number of handlers and process each drag event
// N times after N re-renders. The per-viewport mousedown listener
// stays per-render (the viewport DOM node is replaced on every render
// anyway) but the window-level mousemove/mouseup pair is persistent.
// onDragMove/onDragEnd are safe no-ops when _dragging is false, so
// installing them once is correct.
let _dragListenersInstalled = false
function _ensureDragListeners() {
    if (_dragListenersInstalled) return
    window.addEventListener('mousemove', onDragMove)
    window.addEventListener('mouseup', onDragEnd)
    _dragListenersInstalled = true
}

function renderPipeline(container, session) {
    if (!container || !session) return
    const rounds = session.rounds || []
    if (rounds.length === 0) {
        container.innerHTML = `<div class="empty"><div class="empty-icon">○</div><div class="empty-msg">${t('home.empty')}</div></div>`
        return
    }

    const isActive = session.status === 'active'
    // Total node count: rounds + 1 ghost node for active sessions
    const totalNodes = isActive ? rounds.length + 1 : rounds.length
    const positions = computePositions(totalNodes)
    const totalW = PL.PADDING * 2 + PL.COLS * PL.NODE_W + (PL.COLS - 1) * PL.GAP_X
    const rows = Math.ceil(totalNodes / PL.COLS)
    const totalH = PL.PADDING * 2 + rows * PL.NODE_H + (rows - 1) * (PL.GAP_Y + PL.TURN_H)

    let svgPaths = ''
    for (let i = 0; i < totalNodes - 1; i++) {
        const isLastEdge = isActive && i === rounds.length - 1
        svgPaths += buildConnector(positions[i], positions[i + 1], isLastEdge)
    }

    let nodesHtml = ''
    rounds.forEach((r, idx) => {
        nodesHtml += renderNodeCard(r, session, positions[idx])
    })

    // Ghost "in progress" node for active sessions
    if (isActive) {
        const ghostPos = positions[rounds.length]
        nodesHtml += renderGhostNode(session, ghostPos)
    }

    _scale = 1; _tx = 0; _ty = 0

    container.innerHTML = `
        <div class="canvas-frame">
            <div class="pl-viewport" id="pl-viewport">
                <div class="pl-controls">
                    <button class="pl-ctrl-btn" onclick="plZoom(0.15)" title="Zoom in">+</button>
                    <button class="pl-ctrl-btn" onclick="plZoom(-0.15)" title="Zoom out">−</button>
                    <button class="pl-ctrl-btn" onclick="plFit()" title="Fit">⊡</button>
                </div>
                <div class="pl-canvas" id="pl-canvas" style="width:${totalW}px;height:${totalH}px">
                    <svg class="pl-svg" width="${totalW}" height="${totalH}" viewBox="0 0 ${totalW} ${totalH}">
                        ${svgPaths}
                    </svg>
                    ${nodesHtml}
                </div>
            </div>
        </div>
        <div class="flyout-overlay" id="flyout-overlay" onclick="if(event.target===this)closeFlyout()">
            <div class="flyout-panel" id="flyout-panel"></div>
        </div>`

    const vp = document.getElementById('pl-viewport')
    vp.addEventListener('wheel', onWheel, { passive: false })
    vp.addEventListener('mousedown', onDragStart)
    _ensureDragListeners()

    setTimeout(() => plFit(), 50)
}

// Incremental pipeline update used by WS-push driven refreshes.
// Appends new node cards for rounds that weren't in the DOM yet,
// updates in place the ones whose verdict / active flag changed,
// refreshes the ghost node, and only touches the SVG connectors'
// paths. The outer #pl-viewport with its zoom / pan / controls is
// left intact, so the user's current view (scale, translate)
// survives across rounds instead of snapping back to fit every
// time a new round arrives.
function _updatePipelineIncremental(container, session) {
    const canvas = container && container.querySelector('#pl-canvas')
    const svg = canvas && canvas.querySelector('.pl-svg')
    if (!canvas || !svg) {
        // No incremental substrate yet (empty state or never
        // rendered). Fall back to the full render path.
        renderPipeline(container, session)
        return
    }
    const rounds = session.rounds || []
    if (rounds.length === 0) {
        renderPipeline(container, session)
        return
    }

    const isActive = session.status === 'active'
    const totalNodes = isActive ? rounds.length + 1 : rounds.length
    const positions = computePositions(totalNodes)
    const totalW = PL.PADDING * 2 + PL.COLS * PL.NODE_W + (PL.COLS - 1) * PL.GAP_X
    const rows = Math.ceil(totalNodes / PL.COLS)
    const totalH = PL.PADDING * 2 + rows * PL.NODE_H + (rows - 1) * (PL.GAP_Y + PL.TURN_H)

    // 1) Update / append real (non-ghost) node cards.
    const existing = Array.from(canvas.querySelectorAll('.canvas-tile:not(.is-queued)'))
    existing.sort((a, b) => Number(a.dataset.round) - Number(b.dataset.round))

    // Put existing nodes into a round-number -> element map so we can
    // update or replace them without assuming DOM order.
    const byRound = new Map(existing.map(el => [Number(el.dataset.round), el]))

    for (let i = 0; i < rounds.length; i++) {
        const r = rounds[i]
        const pos = positions[i]
        const el = byRound.get(r.number)
        if (!el) {
            // New round -> append.
            const tmp = document.createElement('div')
            tmp.innerHTML = renderNodeCard(r, session, pos).trim()
            canvas.appendChild(tmp.firstChild)
            continue
        }
        const verdict = r.verdict || 'unknown'
        const shouldActive = isActive && r.number === session.current_round
        const verdictChanged = el.dataset.verdict !== verdict
        const activeChanged = el.classList.contains('active-round') !== shouldActive
        if (verdictChanged || activeChanged) {
            // Replace the single node in place (cheap) to re-render
            // the verdict dot, active indicator and mini-stats.
            const tmp = document.createElement('div')
            tmp.innerHTML = renderNodeCard(r, session, pos).trim()
            el.replaceWith(tmp.firstChild)
        }
        byRound.delete(r.number)
    }
    // Any leftover entries in byRound are rounds that disappeared
    // from the payload (shouldn't happen in normal flow; defensive).
    for (const el of byRound.values()) el.remove()

    // 2) Ghost node — remove the old one, add a fresh one at the
    // new position when the session is still active.
    const oldGhost = canvas.querySelector('.canvas-tile.is-queued')
    if (oldGhost) oldGhost.remove()
    if (isActive) {
        const ghostPos = positions[rounds.length]
        const tmp = document.createElement('div')
        tmp.innerHTML = renderGhostNode(session, ghostPos).trim()
        canvas.appendChild(tmp.firstChild)
    }

    // 3) Redraw the SVG connectors. The SVG is a single sub-element
    // of the canvas; innerHTML-swapping its <line>/<path> children
    // does not blow away the surrounding canvas or the user's zoom
    // state.
    let svgPaths = ''
    for (let i = 0; i < totalNodes - 1; i++) {
        const isLastEdge = isActive && i === rounds.length - 1
        svgPaths += buildConnector(positions[i], positions[i + 1], isLastEdge)
    }
    svg.innerHTML = svgPaths
    svg.setAttribute('width', String(totalW))
    svg.setAttribute('height', String(totalH))
    svg.setAttribute('viewBox', `0 0 ${totalW} ${totalH}`)

    // 4) Canvas size may have grown (new row).
    canvas.style.width = `${totalW}px`
    canvas.style.height = `${totalH}px`
}

// Expose for app.js's targeted refresh path. Kept as a window
// property (rather than a module export) to match the project's
// existing non-modular script loading.
window._updatePipelineIncremental = _updatePipelineIncremental

function computePositions(count) {
    const positions = []
    for (let i = 0; i < count; i++) {
        const row = Math.floor(i / PL.COLS)
        const colInRow = i % PL.COLS
        const reversed = row % 2 === 1
        const col = reversed ? (PL.COLS - 1 - colInRow) : colInRow
        positions.push({
            x: PL.PADDING + col * (PL.NODE_W + PL.GAP_X),
            y: PL.PADDING + row * (PL.NODE_H + PL.GAP_Y + PL.TURN_H),
            row, col, reversed
        })
    }
    return positions
}

function buildConnector(a, b, animated) {
    const ay = a.y + PL.NODE_H / 2
    const by = b.y + PL.NODE_H / 2
    const cls = animated ? 'class="pl-edge-active"' : ''
    const color = animated ? 'var(--accent)' : 'var(--border-2)'
    const style = `fill="none" stroke="${color}" stroke-width="2" stroke-dasharray="6 4" ${cls}`

    if (a.row === b.row) {
        const x1 = a.reversed ? a.x : a.x + PL.NODE_W
        const x2 = a.reversed ? b.x + PL.NODE_W : b.x
        return `<line x1="${x1}" y1="${ay}" x2="${x2}" y2="${ay}" ${style}/>`
    }

    const exitX = a.reversed ? a.x : a.x + PL.NODE_W
    const enterX = b.reversed ? b.x + PL.NODE_W : b.x
    const midY = (a.y + PL.NODE_H + b.y) / 2
    const sideX = a.reversed ? Math.min(a.x, b.x) - PL.GAP_X * 0.4 : Math.max(a.x + PL.NODE_W, b.x + PL.NODE_W) + PL.GAP_X * 0.4

    return `<path d="M${exitX},${ay} L${sideX},${ay} L${sideX},${by} L${enterX},${by}" ${style}/>`
}

function renderNodeCard(r, session, pos) {
    const hasSummary = !!selectLang(r.summary)
    const verdict = r.verdict || 'unknown'
    const isActive = session.status === 'active' && r.number === session.current_round
    const phaseLabel = r.number === 0 ? t('node.setup') : (t(`phase.${r.phase}`) || r.phase)

    const stats = []
    if (r.duration_minutes) stats.push(`${r.duration_minutes}${t('unit.min')}`)
    if (r.bitlesson_delta && r.bitlesson_delta !== 'none') stats.push('BL+')
    if (!hasSummary) stats.push('…')

    // Reference-kit canvas tile: verdict-colored left stripe, mono
    // micro-stats row, optional sweep-bar when the node is the
    // in-flight round. Positioning / connector logic still driven
    // by the snake-path layout above.
    const classes = ['canvas-tile']
    classes.push(`verdict-${verdict}`)
    if (isActive) classes.push('is-running')

    const headLeft = `
        <span class="canvas-num">R${r.number}</span>
        <span class="canvas-tile-meta" title="${_esc(phaseLabel)}">${esc(phaseLabel)}</span>
    `
    const headRight = isActive
        ? '<span class="live-dot" title="in-flight"></span>'
        : `<span class="vdot" data-verdict="${_esc(verdict)}" title="${_esc(verdict)}"></span>`

    const statsRow = stats.length
        ? `<div class="canvas-tile-stats">${stats.map(s => `<span>${esc(s)}</span>`).join('<span class="vdot" data-verdict="unknown" style="opacity:0.4"></span>')}</div>`
        : `<div class="canvas-tile-stats" style="color:var(--text-3)">${esc(verdict)}</div>`

    const runningBar = isActive
        ? '<div class="canvas-bar"><div class="canvas-bar-fill"></div></div>'
        : ''

    return `
        <div class="${classes.join(' ')}" data-verdict="${_esc(verdict)}" data-round="${r.number}"
             style="left:${pos.x}px;top:${pos.y}px;width:${PL.NODE_W}px;height:${PL.NODE_H}px"
             onclick="openFlyout(this, ${r.number})">
            ${runningBar}
            <div class="canvas-tile-head">
                <div style="display:flex;align-items:center;gap:6px;min-width:0">${headLeft}</div>
                ${headRight}
            </div>
            ${statsRow}
        </div>`
}

function renderGhostNode(session, pos) {
    const nextRound = session.current_round + 1
    // Reference-kit "queued / awaiting" tile: dashed accent border,
    // dim, no click handler. Paired with the pl-edge-active
    // animated connector drawn in the SVG layer above.
    return `
        <div class="canvas-tile is-queued"
             style="left:${pos.x}px;top:${pos.y}px;width:${PL.NODE_W}px;height:${PL.NODE_H}px">
            <div class="canvas-tile-head">
                <div style="display:flex;align-items:center;gap:6px">
                    <span class="canvas-num" style="color:var(--text-2)">R${nextRound}</span>
                    <span class="canvas-tile-meta">Next</span>
                </div>
                <span class="spinner" style="width:10px;height:10px"></span>
            </div>
            <div class="canvas-tile-stats" style="color:var(--accent)">Awaiting…</div>
        </div>`
}


// ─── Flyout Modal (expand from node to center) ───

function openFlyout(nodeEl, roundNum) {
    if (_dragging) return
    const session = window._currentSession
    if (!session) return
    const round = session.rounds.find(r => r.number === roundNum)
    if (!round) return

    // Auto-collapse the session-detail log panel while the flyout is
    // open so the reader has more screen real estate for the node's
    // expanded details. closeFlyout() restores whatever state the
    // user had (normal/expanded) before the click.
    if (typeof window.autoCollapseSessionLog === 'function') {
        window.autoCollapseSessionLog()
    }

    const overlay = document.getElementById('flyout-overlay')
    const panel = document.getElementById('flyout-panel')
    if (!overlay || !panel) return

    // Get node position on screen
    const rect = nodeEl.getBoundingClientRect()
    const vpRect = overlay.parentElement.getBoundingClientRect()

    // Set initial position to match node
    panel.style.transition = 'none'
    panel.style.left = (rect.left - vpRect.left) + 'px'
    panel.style.top = (rect.top - vpRect.top) + 'px'
    panel.style.width = rect.width + 'px'
    panel.style.height = rect.height + 'px'
    panel.style.opacity = '0.7'
    panel.style.borderRadius = '14px'
    panel.innerHTML = ''

    // Show overlay
    overlay.classList.add('visible')

    // Animate to center
    requestAnimationFrame(() => {
        requestAnimationFrame(() => {
            const targetW = Math.min(720, vpRect.width - 80)
            const targetH = Math.min(vpRect.height - 100, 600)
            const targetL = (vpRect.width - targetW) / 2
            const targetT = (vpRect.height - targetH) / 2

            panel.style.transition = 'all 400ms cubic-bezier(0.16, 1, 0.3, 1)'
            panel.style.left = targetL + 'px'
            panel.style.top = targetT + 'px'
            panel.style.width = targetW + 'px'
            panel.style.height = targetH + 'px'
            panel.style.opacity = '1'
            panel.style.borderRadius = '20px'

            // Fill content after animation starts
            setTimeout(() => {
                panel.innerHTML = buildFlyoutContent(round, session)
            }, 150)
        })
    })
}

function closeFlyout() {
    const overlay = document.getElementById('flyout-overlay')
    const panel = document.getElementById('flyout-panel')
    if (!overlay || !panel) return

    panel.style.transition = 'all 300ms cubic-bezier(0.45, 0, 0.55, 1)'
    panel.style.opacity = '0'
    panel.style.transform = 'scale(0.9)'

    setTimeout(() => {
        overlay.classList.remove('visible')
        panel.style.transform = ''
        panel.innerHTML = ''
    }, 300)

    // Restore the log panel to whatever state it had before the
    // flyout auto-collapsed it.
    if (typeof window.restoreSessionLog === 'function') {
        window.restoreSessionLog()
    }
}

function buildFlyoutContent(round, session) {
    const verdict = round.verdict || 'unknown'
    const phaseLabel = round.number === 0 ? t('node.setup') : (t(`phase.${round.phase}`) || round.phase)
    const summary = selectLang(round.summary)
    const review = selectLang(round.review_result)

    const summaryHtml = summary ? safeMd(summary) : `<em style="color:var(--text-3)">${t('detail.no_summary')}</em>`
    const reviewHtml = review ? safeMd(review) : `<em style="color:var(--text-3)">${t('detail.no_review')}</em>`

    let metaItems = `
        <span class="flyout-meta-item"><strong>${t('detail.phase')}:</strong> ${esc(phaseLabel)}</span>
        <span class="flyout-meta-item"><strong>${t('card.verdict')}:</strong> <span class="verdict-${verdict}">${verdict}</span></span>`
    if (round.duration_minutes) metaItems += `<span class="flyout-meta-item"><strong>${t('card.duration')}:</strong> ${round.duration_minutes} ${t('unit.min')}</span>`
    if (round.bitlesson_delta && round.bitlesson_delta !== 'none') metaItems += `<span class="flyout-meta-item"><strong>${t('detail.bitlesson')}:</strong> ${round.bitlesson_delta} 📚</span>`
    if (round.task_progress != null) metaItems += `<span class="flyout-meta-item"><strong>${t('detail.tasks')}:</strong> ${round.task_progress}/${session.tasks_total || '?'}</span>`

    return `
        <div class="flyout-header">
            <div class="flyout-title">
                <span class="flyout-round-badge" style="border-color:var(--verdict-${verdict})">R${round.number}</span>
                <h3>${t('card.round')} ${round.number}</h3>
            </div>
            <button class="flyout-close" onclick="closeFlyout()">✕</button>
        </div>
        <div class="flyout-meta-bar">${metaItems}</div>
        <div class="flyout-body">
            <div class="flyout-section">
                <h4 class="flyout-section-title">${t('detail.summary')}</h4>
                <div class="md">${summaryHtml}</div>
            </div>
            <div class="flyout-section">
                <h4 class="flyout-section-title">${t('detail.review')}</h4>
                <div class="md">${reviewHtml}</div>
            </div>
        </div>`
}

// ─── Zoom / Pan ───
function applyTransform() {
    const canvas = document.getElementById('pl-canvas')
    if (canvas) canvas.style.transform = `translate(${_tx}px, ${_ty}px) scale(${_scale})`
}

function plZoom(delta) {
    _scale = Math.max(0.3, Math.min(2.5, _scale + delta))
    applyTransform()
}

function plFit() {
    const vp = document.getElementById('pl-viewport')
    const canvas = document.getElementById('pl-canvas')
    if (!vp || !canvas) return
    const vpW = vp.clientWidth, vpH = vp.clientHeight
    const cW = parseInt(canvas.style.width), cH = parseInt(canvas.style.height)
    _scale = Math.min(vpW / cW, vpH / cH, 1) * 0.92
    _tx = (vpW - cW * _scale) / 2
    _ty = Math.max(8, (vpH - cH * _scale) / 2)
    applyTransform()
}

function onWheel(e) {
    e.preventDefault()
    const delta = e.deltaY > 0 ? -0.08 : 0.08
    const rect = e.currentTarget.getBoundingClientRect()
    const mx = e.clientX - rect.left, my = e.clientY - rect.top
    const oldScale = _scale
    _scale = Math.max(0.3, Math.min(2.5, _scale + delta))
    const ratio = _scale / oldScale
    _tx = mx - ratio * (mx - _tx)
    _ty = my - ratio * (my - _ty)
    applyTransform()
}

function onDragStart(e) {
    if (e.target.closest('.canvas-tile') || e.target.closest('.pl-ctrl-btn')) return
    _dragging = true
    _dragStartX = e.clientX; _dragStartY = e.clientY
    _dragTx = _tx; _dragTy = _ty
    e.currentTarget.style.cursor = 'grabbing'
}

function onDragMove(e) {
    if (!_dragging) return
    _tx = _dragTx + (e.clientX - _dragStartX)
    _ty = _dragTy + (e.clientY - _dragStartY)
    applyTransform()
}

function onDragEnd() {
    if (!_dragging) return
    _dragging = false
    const vp = document.getElementById('pl-viewport')
    if (vp) vp.style.cursor = ''
}

function esc(str) {
    const d = document.createElement('div')
    d.textContent = str || ''
    return d.innerHTML
}
