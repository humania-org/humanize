/* Action handlers — cancel, export, GitHub issue, plan viewer */

function toggleOpsMenu() {
    const menu = document.getElementById('ops-dropdown')
    if (menu) menu.classList.toggle('open')
}

document.addEventListener('click', (e) => {
    if (!e.target.closest('.dropdown'))
        document.querySelectorAll('.dropdown-menu').forEach(m => m.classList.remove('open'))
})

// ─── Cancel ───
function showCancelModal(sessionId) {
    const modal = document.getElementById('modal-content')
    modal.innerHTML = `
        <h3>${t('cancel.title')}</h3>
        <p style="color:var(--text-1);margin-bottom:var(--space-4)">${t('cancel.message')}</p>
        <div class="modal-actions">
            <button class="btn btn-ghost" onclick="closeModal()">${t('cancel.dismiss')}</button>
            <button class="btn btn-danger" onclick="confirmCancel('${sessionId}')">${t('cancel.confirm')}</button>
        </div>`
    document.getElementById('modal-overlay').classList.add('visible')
}

async function confirmCancel(sessionId) {
    const res = await window.authedFetch(`/api/sessions/${sessionId}/cancel`, { method: 'POST' })
    closeModal()
    if (res.ok) window.renderCurrentRoute()
    else { const e = await res.json(); alert(e.error || t('cancel.failed')) }
}

function closeModal() {
    document.getElementById('modal-overlay').classList.remove('visible')
}

// ─── Export ───
async function exportMarkdown(sessionId) {
    const res = await window.authedFetch(`/api/sessions/${sessionId}/export`, { method: 'POST' })
    if (!res.ok) return
    const data = await res.json()
    const blob = new Blob([data.content], { type: 'text/markdown' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = data.filename || `rlcr-report-${sessionId}.md`
    a.click()
    URL.revokeObjectURL(url)
}

function exportPdf() { window.print() }

// ─── GitHub Issue (sanitized) ───
async function previewGitHubIssue(sessionId) {
    const res = await window.authedFetch(`/api/sessions/${sessionId}/sanitized-issue`)
    if (!res.ok) return
    const data = await res.json()
    const modal = document.getElementById('modal-content')
    modal.innerHTML = `
        <h3>${t('analysis.preview')}</h3>
        <div style="margin-bottom:var(--space-4)">
            <div class="meta-item-label">${t('analysis.issue_title')}</div>
            <code style="display:block;padding:var(--space-3);background:var(--bg-3);border-radius:var(--radius-sm);margin-top:var(--space-1);font-size:0.85rem">${esc(data.title)}</code>
        </div>
        <div>
            <div class="meta-item-label">${t('analysis.issue_body')}</div>
            <div class="md" style="max-height:50vh;overflow-y:auto;padding:var(--space-4);background:var(--bg-3);border-radius:var(--radius-sm);margin-top:var(--space-1)">
                ${safeMd(data.body)}
            </div>
        </div>
        <div class="modal-actions">
            <button class="btn btn-ghost" onclick="closeModal()">${t('cancel.dismiss')}</button>
            <button class="btn" onclick="copyIssueContent('${sessionId}')">${t('analysis.copy')}</button>
            <button class="btn btn-primary" onclick="sendGitHubIssue('${sessionId}')">${t('analysis.send')}</button>
        </div>`
    document.getElementById('modal-overlay').classList.add('visible')
}

async function sendGitHubIssue(sessionId) {
    closeModal()
    const ghResult = document.getElementById('gh-result')
    if (ghResult) ghResult.innerHTML = `<span style="color:var(--text-2)">${t('analysis.sending')}</span>`
    const res = await window.authedFetch(`/api/sessions/${sessionId}/github-issue`, { method: 'POST' })
    const data = await res.json()
    if (res.ok && data.url) {
        if (ghResult) ghResult.innerHTML = `<span style="color:var(--verdict-advanced)">✓ ${t('analysis.sent')} — <a href="${data.url}" target="_blank">${data.url}</a></span>`
    } else if (data.manual) {
        window._issuePayload = `Title: ${data.title || ''}\n\n${data.body || ''}`
        if (ghResult) ghResult.innerHTML = `<span style="color:var(--verdict-stalled)">${esc(data.error)}</span><br><button class="btn" style="margin-top:var(--space-2)" onclick="copyToClipboard(window._issuePayload)">${t('analysis.copy')}</button>`
    } else {
        if (ghResult) ghResult.innerHTML = `<span style="color:var(--verdict-regressed)">${esc(data.error || t('analysis.failed'))}</span>`
    }
}

async function copyIssueContent(sessionId) {
    const res = await window.authedFetch(`/api/sessions/${sessionId}/sanitized-issue`)
    if (!res.ok) return
    const data = await res.json()
    copyToClipboard(`Title: ${data.title}\n\n${data.body}`)
}

function copyToClipboard(text) {
    navigator.clipboard.writeText(text).catch(() => {
        const ta = document.createElement('textarea')
        ta.value = text
        document.body.appendChild(ta)
        ta.select()
        document.execCommand('copy')
        document.body.removeChild(ta)
    })
}

// ─── Generate Report (calls local Claude CLI) ───
async function ensureReport(sessionId) {
    const resultEl = document.getElementById('sidebar-gh-result')

    // Try sanitized-issue first — if it works, report exists
    const check = await window.authedFetch(`/api/sessions/${sessionId}/sanitized-issue`)
    if (check.ok) {
        const data = await check.json()
        if (!data.requires_review || data.body !== '[REDACTED — outbound payload failed validation.]') {
            return true
        }
    }

    // No report — generate one via Claude CLI
    if (resultEl) resultEl.innerHTML = `
        <div style="padding:var(--space-3);background:var(--bg-3);border-radius:var(--radius-sm);font-size:0.8rem">
            <div style="display:flex;align-items:center;gap:var(--space-2);color:var(--accent)">
                <span class="spinner"></span>
                Generating methodology report via Claude...
            </div>
            <div style="color:var(--text-3);font-size:0.72rem;margin-top:var(--space-2)">
                This may take 30-60 seconds. Analyzing round summaries and reviews.
            </div>
        </div>`

    try {
        const res = await window.authedFetch(`/api/sessions/${sessionId}/generate-report`, { method: 'POST' })
        const data = await res.json()

        if (res.ok && (data.status === 'generated' || data.status === 'exists')) {
            if (resultEl) resultEl.innerHTML = `
                <div style="padding:var(--space-2);font-size:0.78rem;color:var(--verdict-advanced)">
                    ✓ Report generated successfully
                </div>`
            return true
        } else {
            if (resultEl) resultEl.innerHTML = `
                <div style="padding:var(--space-3);background:rgba(248,113,113,0.06);border:1px solid var(--verdict-regressed);border-radius:var(--radius-sm);font-size:0.8rem">
                    <span style="color:var(--verdict-regressed)">${esc(data.error || 'Failed to generate report')}</span>
                </div>`
            return false
        }
    } catch (e) {
        if (resultEl) resultEl.innerHTML = `
            <div style="padding:var(--space-3);background:rgba(248,113,113,0.06);border:1px solid var(--verdict-regressed);border-radius:var(--radius-sm);font-size:0.8rem">
                <span style="color:var(--verdict-regressed)">Network error: ${esc(e.message)}</span>
            </div>`
        return false
    }
}

async function sidebarGenerateAndPreview(sessionId) {
    const ok = await ensureReport(sessionId)
    if (ok) await sidebarPreviewIssue(sessionId)
}

async function sidebarGenerateAndSend(sessionId) {
    const ok = await ensureReport(sessionId)
    if (ok) await sidebarSendIssue(sessionId)
}

// ─── Sidebar Issue Submission ───
async function sidebarPreviewIssue(sessionId) {
    const resultEl = document.getElementById('sidebar-gh-result')
    if (resultEl) resultEl.innerHTML = `<span style="color:var(--text-3);font-size:0.8rem">Loading preview...</span>`

    const res = await window.authedFetch(`/api/sessions/${sessionId}/sanitized-issue`)
    if (!res.ok) {
        if (resultEl) resultEl.innerHTML = `<span style="color:var(--verdict-regressed);font-size:0.8rem">No methodology report available for this session.</span>`
        return
    }

    const data = await res.json()

    // Check for warnings
    const w = data.warnings || {}
    const hasWarnings = data.requires_review || Object.keys(w).length > 0

    const modal = document.getElementById('modal-content')
    modal.innerHTML = `
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:var(--space-4)">
            <h3 style="margin:0">Issue Preview</h3>
            <span style="font-size:0.75rem;color:var(--text-3)">→ PolyArch/humanize</span>
        </div>
        ${hasWarnings ? `
            <div class="warning-banner" style="margin-bottom:var(--space-4)">
                ⚠ Sanitization warnings detected. Content has been redacted.<br>
                ${Object.entries(w).map(([c, n]) => `<span style="margin-right:8px">• ${esc(c)}: ${n}</span>`).join('')}
            </div>` : ''}
        <div style="margin-bottom:var(--space-4)">
            <div style="font-size:0.72rem;font-weight:700;text-transform:uppercase;letter-spacing:0.06em;color:var(--text-3);margin-bottom:4px">Title</div>
            <code style="display:block;padding:var(--space-3);background:var(--bg-3);border-radius:var(--radius-sm);font-size:0.85rem;word-break:break-all">${esc(data.title)}</code>
        </div>
        <div>
            <div style="font-size:0.72rem;font-weight:700;text-transform:uppercase;letter-spacing:0.06em;color:var(--text-3);margin-bottom:4px">Body</div>
            <div class="md" style="max-height:45vh;overflow-y:auto;padding:var(--space-4);background:var(--bg-3);border-radius:var(--radius-sm)">
                ${safeMd(data.body)}
            </div>
        </div>
        <div class="modal-actions">
            <button class="btn btn-ghost" onclick="closeModal()">Close</button>
            <button class="btn" onclick="copyIssueContent('${sessionId}');closeModal()">Copy</button>
            ${!hasWarnings ? `<button class="btn btn-primary" onclick="sidebarSendIssue('${sessionId}');closeModal()">Submit</button>` : ''}
        </div>`
    document.getElementById('modal-overlay').classList.add('visible')
    if (resultEl) resultEl.innerHTML = ''
}

async function sidebarSendIssue(sessionId) {
    const resultEl = document.getElementById('sidebar-gh-result')
    if (resultEl) resultEl.innerHTML = `<span style="color:var(--text-2);font-size:0.8rem">Submitting...</span>`

    const res = await window.authedFetch(`/api/sessions/${sessionId}/github-issue`, { method: 'POST' })
    const data = await res.json()

    if (res.ok && data.url) {
        if (resultEl) resultEl.innerHTML = `
            <div style="padding:var(--space-3);background:rgba(110,231,160,0.06);border:1px solid var(--verdict-advanced);border-radius:var(--radius-sm);font-size:0.8rem">
                <span style="color:var(--verdict-advanced)">✓ Issue created</span><br>
                <a href="${data.url}" target="_blank" style="font-size:0.75rem;word-break:break-all">${data.url}</a>
            </div>`
        // Disable buttons after successful submission
        const actionsEl = document.getElementById('sidebar-gh-actions')
        if (actionsEl) actionsEl.innerHTML = `<div style="font-size:0.8rem;color:var(--verdict-advanced)">✓ Submitted</div>`
    } else if (data.manual) {
        window._issuePayload = `Title: ${data.title || ''}\n\n${data.body || ''}`
        if (resultEl) resultEl.innerHTML = `
            <div style="padding:var(--space-3);background:rgba(251,191,36,0.06);border:1px solid var(--verdict-stalled);border-radius:var(--radius-sm);font-size:0.8rem">
                <span style="color:var(--verdict-stalled)">${esc(data.error)}</span><br>
                <button class="btn" style="margin-top:var(--space-2);font-size:0.75rem" onclick="copyToClipboard(window._issuePayload)">Copy issue content</button>
            </div>`
    } else if (data.warnings) {
        if (resultEl) resultEl.innerHTML = `
            <div style="padding:var(--space-3);background:rgba(251,191,36,0.06);border:1px solid var(--verdict-stalled);border-radius:var(--radius-sm);font-size:0.8rem">
                <span style="color:var(--verdict-stalled)">⚠ Sanitization check failed</span><br>
                <span style="font-size:0.72rem;color:var(--text-3)">${Object.entries(data.warnings).map(([c, n]) => `${c}: ${n}`).join(', ')}</span>
            </div>`
    } else {
        if (resultEl) resultEl.innerHTML = `
            <div style="padding:var(--space-3);background:rgba(248,113,113,0.06);border:1px solid var(--verdict-regressed);border-radius:var(--radius-sm);font-size:0.8rem">
                <span style="color:var(--verdict-regressed)">${esc(data.error || 'Submission failed')}</span>
            </div>`
    }
}

// ─── Ops-menu Preview + Submit flow ───
//
// Combines generate-report (local Claude CLI, humanize issue
// taxonomy, forbidden-token scan, report body assembled against a
// constrained methodology vocabulary) with preview + gh-issue
// submission into one user-visible operation reachable from the
// session-detail ops dropdown. Three states share the same modal:
// generating -> preview -> submitting -> result.

async function opsPreviewIssue(sessionId) {
    if (!sessionId) return
    _opsShowModal(`
        <h3>${t('ops.preview_issue')}</h3>
        <div style="display:flex;align-items:center;gap:var(--space-3);padding:var(--space-3) 0">
            <span class="spinner"></span>
            <div>
                <div>Generating methodology report via local Claude CLI…</div>
                <div style="color:var(--text-3);font-size:0.78rem;margin-top:4px">Typically 30–60s. Output is sanitized and mapped to a constrained methodology taxonomy before preview.</div>
            </div>
        </div>
        <div class="modal-actions">
            <button class="btn btn-ghost" onclick="closeModal()">${t('cancel.dismiss')}</button>
        </div>`)

    // Step 1: check if the sanitized-issue payload already builds
    // cleanly (i.e. a methodology-analysis-report.md exists). If
    // not, generate one via local Claude CLI, then re-check.
    let check = await window.authedFetch(`/api/sessions/${sessionId}/sanitized-issue`)
    if (!check.ok) {
        const gen = await window.authedFetch(`/api/sessions/${sessionId}/generate-report`, { method: 'POST' })
        const genData = await gen.json().catch(() => ({}))
        if (!gen.ok) {
            _opsShowError(t('analysis.failed'), genData.error || 'Failed to generate methodology report via local Claude CLI.', genData.stderr)
            return
        }
        check = await window.authedFetch(`/api/sessions/${sessionId}/sanitized-issue`)
    }

    if (!check.ok) {
        _opsShowError(t('analysis.failed'), 'Sanitized issue payload could not be built for this session.')
        return
    }

    const data = await check.json()
    const w = data.warnings || {}
    const hasWarnings = !!data.requires_review || Object.keys(w).length > 0

    const warningBanner = hasWarnings
        ? `<div class="warning-banner" style="margin-bottom:var(--space-4)">
               ${t('analysis.review_warning')}<br>
               ${Object.entries(w).map(([c, n]) => `<span style="margin-right:8px">• ${esc(c)}: ${n}</span>`).join('')}
           </div>`
        : ''

    _opsShowModal(`
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:var(--space-4)">
            <h3 style="margin:0">${t('ops.preview_issue')}</h3>
            <span style="font-size:0.75rem;color:var(--text-3)">→ PolyArch/humanize</span>
        </div>
        ${warningBanner}
        <div style="margin-bottom:var(--space-4)">
            <div class="meta-item-label">${t('analysis.issue_title')}</div>
            <code style="display:block;padding:var(--space-3);background:var(--bg-3);border-radius:var(--radius-sm);margin-top:var(--space-1);font-size:0.85rem;word-break:break-all">${esc(data.title)}</code>
        </div>
        <div>
            <div class="meta-item-label">${t('analysis.issue_body')}</div>
            <div class="md" style="max-height:45vh;overflow-y:auto;padding:var(--space-4);background:var(--bg-3);border-radius:var(--radius-sm);margin-top:var(--space-1)">
                ${safeMd(data.body)}
            </div>
        </div>
        <div class="modal-actions">
            <button class="btn btn-ghost" onclick="closeModal()">${t('cancel.dismiss')}</button>
            <button class="btn" onclick="opsCopyIssue('${sessionId}')">${t('analysis.copy')}</button>
            ${hasWarnings ? '' : `<button class="btn btn-primary" onclick="opsSubmitIssue('${sessionId}')">${t('analysis.send')}</button>`}
        </div>`)
}

async function opsSubmitIssue(sessionId) {
    _opsShowModal(`
        <h3>${t('analysis.sending')}</h3>
        <div style="display:flex;align-items:center;gap:var(--space-3);padding:var(--space-3) 0">
            <span class="spinner"></span>
            <div>
                <div>Creating GitHub issue on PolyArch/humanize via gh CLI…</div>
                <div style="color:var(--text-3);font-size:0.78rem;margin-top:4px">Requires a gh login on this host (run <code>gh auth login</code> once).</div>
            </div>
        </div>
        <div class="modal-actions">
            <button class="btn btn-ghost" onclick="closeModal()">${t('cancel.dismiss')}</button>
        </div>`)

    const res = await window.authedFetch(`/api/sessions/${sessionId}/github-issue`, { method: 'POST' })
    const data = await res.json().catch(() => ({}))

    if (res.ok && data.url) {
        _opsShowModal(`
            <h3 style="color:var(--verdict-advanced)">✓ ${t('analysis.sent')}</h3>
            <div style="padding:var(--space-3) 0;font-size:0.9rem">
                <a href="${esc(data.url)}" target="_blank" style="color:var(--accent);word-break:break-all">${esc(data.url)}</a>
            </div>
            <div class="modal-actions">
                <button class="btn btn-primary" onclick="closeModal()">OK</button>
            </div>`)
        return
    }

    if (data.manual) {
        // gh CLI missing or unauthenticated. Make the payload
        // trivially copyable so the user can file the issue manually.
        window._issuePayload = `Title: ${data.title || ''}\n\n${data.body || ''}`
        _opsShowModal(`
            <h3>${t('analysis.failed')}</h3>
            <div class="warning-banner">${esc(data.error || 'gh CLI is not available on this host.')}</div>
            <div style="color:var(--text-2);font-size:0.82rem;margin:var(--space-3) 0">
                Run <code>gh auth login</code> in the same shell that launched <code>humanize monitor web</code>, then retry.
                Alternatively copy the payload below and file the issue manually against PolyArch/humanize.
            </div>
            <div class="modal-actions">
                <button class="btn btn-ghost" onclick="closeModal()">${t('cancel.dismiss')}</button>
                <button class="btn btn-primary" onclick="copyToClipboard(window._issuePayload);closeModal()">${t('analysis.copy')}</button>
            </div>`)
        return
    }

    if (data.warnings) {
        _opsShowError(
            t('analysis.failed'),
            'Sanitization check failed on the final payload. Review the methodology report manually and strip any project-specific tokens before sending.',
            Object.entries(data.warnings).map(([c, n]) => `${c}: ${n}`).join(', '),
        )
        return
    }

    _opsShowError(t('analysis.failed'), data.error || 'Issue creation failed.')
}

async function opsCopyIssue(sessionId) {
    await copyIssueContent(sessionId)
}

function _opsShowModal(inner) {
    const modal = document.getElementById('modal-content')
    if (!modal) return
    modal.innerHTML = inner
    document.getElementById('modal-overlay').classList.add('visible')
}

function _opsShowError(title, message, detail) {
    _opsShowModal(`
        <h3>${esc(title)}</h3>
        <div class="warning-banner">${esc(message)}</div>
        ${detail ? `<pre style="background:var(--bg-3);padding:var(--space-3);border-radius:var(--radius-sm);font-size:0.75rem;max-height:30vh;overflow:auto;white-space:pre-wrap">${esc(detail)}</pre>` : ''}
        <div class="modal-actions">
            <button class="btn btn-ghost" onclick="closeModal()">${t('cancel.dismiss')}</button>
        </div>`)
}

// Project switching removed in Round 5 (T10-frontend). The dashboard
// is now CLI-fixed to one project at startup; multi-project users run
// `humanize monitor web --project <path>` per project. The legacy
// /api/projects/{switch,add,remove} endpoints return 410 Gone.

// ─── Plan Viewer ───
async function showPlanViewer(sessionId) {
    const res = await window.authedFetch(`/api/sessions/${sessionId}/plan`)
    if (!res.ok) return
    const data = await res.json()
    const modal = document.getElementById('modal-content')
    modal.innerHTML = `
        <h3>${t('ops.view_plan')}</h3>
        <div class="md" style="max-height:70vh;overflow-y:auto">${safeMd(data.content)}</div>
        <div class="modal-actions"><button class="btn btn-ghost" onclick="closeModal()">${t('cancel.dismiss')}</button></div>`
    document.getElementById('modal-overlay').classList.add('visible')
}
