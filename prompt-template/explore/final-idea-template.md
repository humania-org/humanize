# <TITLE>

## Run Context

- Run ID: <RUN_ID>
- Directions JSON: <DIRECTIONS_JSON_FILE>
- Explore Report: <REPORT_PATH>
- Final Idea: <FINAL_IDEA_PATH>

## Final Recommendation

<FINAL_RECOMMENDATION>

## Rationale

<RATIONALE>

## Approach Summary

<APPROACH_SUMMARY>

## Objective Evidence

<OBJECTIVE_EVIDENCE>

## Explore Outcomes

<EXPLORE_OUTCOMES>

## Constraints

<CONSTRAINTS>

## Known Risks

<KNOWN_RISKS>

## Cross-Direction Learnings

<CROSS_DIRECTION_LEARNINGS>

## Suggested Productization Flow

```bash
/humanize:gen-plan --input <FINAL_IDEA_PATH> --output <plan-path>
/humanize:start-rlcr-loop <plan-path>
```
