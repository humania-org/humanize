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
    'analytics.rounds_trend': 'Rounds per Session',
    'analytics.duration': 'Avg Round Duration (min)',
    'analytics.verdicts': 'Verdict Distribution',
    'analytics.p_issues': 'P0-P9 Issues',
    'analytics.first_complete': 'First COMPLETE Round',
    'analytics.bl_growth': 'BitLesson Growth',
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

// Safe Markdown rendering — parse then sanitize to prevent XSS
function safeMd(text) {
    if (!text) return ''
    const html = marked.parse(text)
    return typeof DOMPurify !== 'undefined' ? DOMPurify.sanitize(html) : html
}
