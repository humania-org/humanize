# PR Loop Goal Tracker

## PR Information

- **PR Number:** #{{PR_NUMBER}}
- **Branch:** {{START_BRANCH}}
- **Monitored Bots:** {{ACTIVE_BOTS_DISPLAY}}
- **Startup Case:** {{STARTUP_CASE}}

## Ultimate Goal

Get all monitored bot reviewers ({{ACTIVE_BOTS_DISPLAY}}) to approve this PR.

## Acceptance Criteria

| AC | Description | Bot | Status |
|----|-------------|-----|--------|
{{BOT_AC_ROWS}}

## Current Status

### Round 0: Initialization

- **Phase:** Waiting for initial bot reviews
- **Active Bots:** {{ACTIVE_BOTS_DISPLAY}}
- **Approved Bots:** (none yet)

### Open Issues

| Round | Bot | Issue | Status |
|-------|-----|-------|--------|
| - | - | (awaiting initial reviews) | pending |

### Addressed Issues

| Round | Bot | Issue | Resolution |
|-------|-----|-------|------------|

## Log

| Round | Timestamp | Event |
|-------|-----------|-------|
| 0 | {{STARTED_AT}} | PR loop initialized (Case {{STARTUP_CASE}}) |
