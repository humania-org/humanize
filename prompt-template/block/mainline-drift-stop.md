# Mainline Drift Circuit Breaker

The RLCR loop has been stopped because the implementation failed to advance the mainline for **{{STALL_COUNT}} consecutive rounds**.

- Last mainline verdict: `{{LAST_VERDICT}}`
- Plan anchor: `{{PLAN_FILE}}`
- Drift status: `replan_required`

This loop should not continue automatically.

Next action:
1. Re-read the original plan
2. Identify why recent rounds kept stalling or regressing
3. Start a fresh RLCR loop with a narrower recovered mainline objective
