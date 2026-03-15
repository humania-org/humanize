# Mainline Verdict Missing

The implementation review output is missing the required line:

`Mainline Progress Verdict: ADVANCED / STALLED / REGRESSED`

Humanize cannot safely update the drift state or choose the correct next-round prompt without this verdict.

Retry the exit so Codex reruns the implementation review.

Files:
- Review result: {{REVIEW_RESULT_FILE}}
- Review prompt: {{REVIEW_PROMPT_FILE}}
