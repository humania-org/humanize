/* UI labels — English only */

const _LABELS = {
    'app.title': 'Humanize Viz',
    'nav.analytics': 'Analytics',
    'nav.back': '← Back',
    'home.active': 'Active',
    'home.completed': 'Completed',
    'home.empty': 'No RLCR sessions found',
    'home.empty.hint': 'Start an RLCR loop in your project and sessions will appear here.',
    'home.rounds_per_day': 'Rounds / day',
    'card.round': 'Round',
    'card.plan': 'Plan',
    'card.branch': 'Branch',
    'card.verdict': 'Verdict',
    'card.ac': 'AC',
    'card.started': 'Started',
    'card.duration': 'Duration',
    'detail.summary': 'Summary',
    'detail.review': 'Codex Review',
    'detail.phase': 'Phase',
    'detail.tasks': 'Tasks',
    'detail.bitlesson': 'BitLesson',
    'detail.no_summary': 'Summary not yet available',
    'detail.no_review': 'Review not yet available',
    'detail.not_found': 'Session not found',
    'detail.click_node': 'Click a node to expand round details',
    'ops.view_plan': 'View Plan',
    'ops.analysis': 'Methodology Analysis',
    'ops.preview_issue': 'Preview Issue',
    'ops.export_md': 'Export Markdown',
    'ops.export_pdf': 'Export PDF',
    'ops.cancel': 'Cancel Loop',
    'cancel.title': 'Confirm Cancel',
    'cancel.message': 'Cancel the current RLCR loop? This cannot be undone.',
    'cancel.confirm': 'Confirm',
    'cancel.dismiss': 'Close',
    'cancel.failed': 'Cancel failed',
    'analysis.report_tab': 'Methodology Report',
    'analysis.summary_tab': 'Sanitized Summary',
    'analysis.no_report': 'Analysis report not yet available',
    'analysis.gh_repo': 'Target repo',
    'analysis.preview': 'Preview Issue',
    'analysis.send': 'Send to GitHub',
    'analysis.copy': 'Copy Content',
    'analysis.sent': 'Sent',
    'analysis.sending': 'Sending...',
    'analysis.failed': 'Failed',
    'analysis.issue_title': 'Title',
    'analysis.issue_body': 'Body',
    'analysis.review_warning': '⚠ Sanitization check found issues. Review the methodology report manually and remove project-specific content before sending.',
    'analytics.title': 'Cross-Session Analytics',
    'analytics.total': 'Total Sessions',
    'analytics.avg_rounds': 'Avg Rounds',
    'analytics.completion': 'Completion Rate',
    'analytics.bitlessons': 'Total BitLessons',
    'analytics.comparison': 'Session Comparison',
    'analytics.no_data': 'No analytics data',
    'analytics.col_session': 'Session',
    'analytics.col_status': 'Status',
    'analytics.rework': 'Rework',
    'status.active': 'Active',
    'status.complete': 'Complete',
    'status.cancel': 'Cancelled',
    'status.stop': 'Stopped',
    'status.maxiter': 'Max Iter',
    'status.unknown': 'Unknown',
    'status.analyzing': 'Analyzing',
    'status.finalizing': 'Finalizing',
    'phase.implementation': 'Impl',
    'phase.code_review': 'Review',
    'phase.finalize': 'Final',
    'node.setup': 'Setup',
    'unit.min': 'min',
}

function t(key) {
    return _LABELS[key] || key
}

// Content language selection from {zh, en} objects — prefer English
function selectLang(content) {
    if (!content) return null
    if (typeof content === 'string') return content
    if (typeof content === 'object') {
        return content['en'] || content['zh'] || null
    }
    return null
}

// Safe Markdown rendering — parse then sanitize to prevent XSS.
// Fails closed to plain-text escape when the DOMPurify CDN dep isn't
// loaded (offline, blocked by firewall, or a CSP that forbids
// unpkg.com). The earlier implementation returned the raw
// marked.parse() output in that case, which re-opens the XSS
// surface the sanitizer was supposed to close — plan files, round
// summaries, review results, methodology reports, and the Preview
// Issue modal all feed markdown into the DOM through this helper.
function safeMd(text) {
    if (!text) return ''
    if (typeof DOMPurify === 'undefined' || typeof marked === 'undefined') {
        // Fall back to escaped plain text so a missing CDN dep is a
        // visible degradation (monospace text) rather than a silent
        // XSS foot-gun. Mirrors the _esc() round-trip that every
        // attribute-level escape in app.js / pipeline.js uses.
        const d = document.createElement('div')
        d.textContent = String(text)
        return `<pre style="white-space:pre-wrap;word-break:break-word;margin:0">${d.innerHTML}</pre>`
    }
    const html = marked.parse(text)
    return DOMPurify.sanitize(html)
}
