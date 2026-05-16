import type { DashboardTheme } from "../config.js";
import { brandHeaderHtml, humanizeFaviconHref } from "./branding.js";

export interface DashboardHtmlOptions {
  defaultTheme?: DashboardTheme;
  appVersion?: string;
}

export function dashboardHtml(options: DashboardHtmlOptions = {}): string {
  const defaultTheme = options.defaultTheme === "light" ? "light" : "dark";
  const appVersion = options.appVersion?.trim() || "unknown";
  const faviconHref = humanizeFaviconHref();

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Humanize2</title>
  <link rel="icon" type="image/svg+xml" href="${faviconHref}">
  <style>
    :root {
      color-scheme: light;
      --page: #f8f0df;
      --surface: #fffdf6;
      --surface-strong: #ffffff;
      --surface-muted: #efe8d7;
      --ink: #171717;
      --muted: #606879;
      --border: #111111;
      --accent: #ffd33d;
      --accent-2: #1a8a9e;
      --accent-3: #ff8a4c;
      --success: #14805d;
      --failed: #b42318;
      --running: #2364aa;
      --stopped: #687586;
      --terminal: #101820;
      --terminal-text: #eef5f7;
      --selection: #b4d5ff;
      --shadow: #111111;
    }
    body[data-theme="dark"] {
      color-scheme: dark;
      --page: #191816;
      --surface: #242424;
      --surface-strong: #2d2d2d;
      --surface-muted: #363330;
      --ink: #f4ecd8;
      --muted: #b7ad9c;
      --border: #f4ecd8;
      --accent: #ffd33d;
      --accent-2: #42c7d8;
      --accent-3: #ff9b63;
      --success: #49d19b;
      --failed: #ff7c70;
      --running: #7db7ff;
      --stopped: #a4b0bd;
      --terminal: #0b0f14;
      --terminal-text: #f3f7fb;
      --selection: #264f78;
      --shadow: #000000;
    }
    * { box-sizing: border-box; }
    [hidden] { display: none !important; }
    ::selection { background: var(--selection); color: var(--ink); }
    body {
      margin: 0;
      min-width: 1020px;
      background: var(--page);
      color: var(--ink);
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      line-height: 1.4;
    }
    button, summary, input { font: inherit; }
    button { color: inherit; }
    .topbar {
      position: relative;
      z-index: 1;
      height: 58px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 18px;
      border-bottom: 3px solid var(--border);
      background: var(--surface-strong);
    }
    h1 {
      margin: 0;
      font-size: 22px;
      font-weight: 850;
      letter-spacing: 0;
    }
    .brand-lockup {
      display: inline-flex;
      align-items: center;
      gap: 9px;
      min-height: 38px;
      padding: 4px 9px 5px 6px;
      border: 3px solid var(--border);
      background: var(--accent);
      color: #111;
      box-shadow: 3px 3px 0 var(--shadow);
      transform: rotate(-1deg);
    }
    .brand-mark {
      display: inline-grid;
      place-items: center;
      width: 28px;
      height: 28px;
      background: var(--surface-strong);
      border: 2px solid var(--border);
      image-rendering: pixelated;
    }
    .polyarch-mark svg {
      width: 22px;
      height: 22px;
      display: block;
    }
    .brand-copy {
      display: grid;
      align-items: center;
      gap: 1px;
      min-width: 0;
    }
    .brand-mainline {
      display: flex;
      align-items: baseline;
      gap: 7px;
      min-width: 0;
    }
    .brand-text {
      font-size: 20px;
      line-height: 1;
      font-weight: 950;
      font-style: italic;
      text-transform: uppercase;
      text-shadow: 2px 2px 0 rgba(255,255,255,.55);
      color: inherit;
      text-decoration: none;
    }
    .brand-version {
      font-size: 11px;
      line-height: 1;
      font-weight: 950;
      white-space: nowrap;
    }
    .brand-byline {
      font-size: 10px;
      line-height: 1;
      font-weight: 850;
      text-transform: none;
      white-space: nowrap;
    }
    .brand-byline a {
      color: inherit;
      text-decoration: underline;
      text-decoration-thickness: 2px;
      text-underline-offset: 2px;
    }
    .top-actions {
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .pixel-button {
      min-height: 32px;
      border: 3px solid var(--border);
      border-radius: 0;
      background: var(--surface-strong);
      box-shadow: 3px 3px 0 var(--shadow);
      padding: 4px 10px;
      cursor: pointer;
      font-size: 12px;
      font-weight: 800;
    }
    .pixel-button:active { transform: translate(2px, 2px); box-shadow: 1px 1px 0 var(--shadow); }
    .dashboard-shell {
      position: relative;
      z-index: 1;
      display: grid;
      grid-template-columns: var(--sidebar-width, 360px) 8px minmax(520px, 1fr) 8px var(--properties-width, 420px);
      gap: 4px;
      height: calc(100vh - 58px);
      min-height: 720px;
      padding: 12px;
      transition: grid-template-columns .16s ease;
    }
    body.sidebar-collapsed .dashboard-shell {
      grid-template-columns: 46px 0 minmax(520px, 1fr) 8px var(--properties-width, 420px);
    }
    body.properties-collapsed .dashboard-shell {
      grid-template-columns: var(--sidebar-width, 360px) 8px minmax(620px, 1fr) 0 46px;
    }
    body.sidebar-collapsed.properties-collapsed .dashboard-shell {
      grid-template-columns: 46px 0 minmax(620px, 1fr) 0 46px;
    }
    .sidebar { grid-column: 1; }
    .sidebar-resizer { grid-column: 2; }
    .workbench { grid-column: 3; }
    .properties-resizer { grid-column: 4; }
    .properties-drawer { grid-column: 5; }
    .layout-resizer,
    .stack-resizer {
      position: relative;
      min-width: 0;
      min-height: 0;
      border: 0;
      background: transparent;
      touch-action: none;
      z-index: 2;
    }
    .layout-resizer {
      cursor: col-resize;
    }
    .stack-resizer {
      height: 8px;
      cursor: row-resize;
    }
    body.timeline-collapsed.transcript-collapsed .workbench {
      grid-template-rows: minmax(0, 1fr) 0 max-content;
    }
    body.timeline-collapsed.transcript-collapsed .chat-resizer {
      height: 0;
      cursor: default;
      pointer-events: none;
    }
    body.timeline-collapsed .details-stack {
      grid-template-rows: max-content 0 minmax(0, 1fr);
    }
    body.transcript-collapsed .details-stack {
      grid-template-rows: minmax(0, 1fr) 0 max-content;
    }
    body.timeline-collapsed.transcript-collapsed .details-stack {
      grid-template-rows: max-content 0 max-content;
    }
    body.timeline-collapsed .timeline-resizer,
    body.transcript-collapsed .timeline-resizer {
      height: 0;
      cursor: default;
      pointer-events: none;
    }
    body.sidebar-collapsed .sidebar-resizer,
    body.properties-collapsed .properties-resizer {
      cursor: default;
      pointer-events: none;
    }
    body.layout-resizing {
      user-select: none;
    }
    .panel {
      min-width: 0;
      min-height: 0;
      border: 3px solid var(--border);
      border-radius: 0;
      background: var(--surface);
      box-shadow: 5px 5px 0 var(--shadow);
      overflow: hidden;
    }
    .panel-title {
      min-height: 42px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      padding: 7px 10px;
      border-bottom: 3px solid var(--border);
      background: var(--surface-strong);
      font-size: 14px;
      font-weight: 850;
    }
    .muted {
      color: var(--muted);
      font-size: 12px;
      font-weight: 650;
    }
    .sidebar, .properties-drawer {
      display: grid;
      grid-template-rows: auto minmax(0, 1fr);
    }
    body.sidebar-collapsed .sidebar .sidebar-body,
    body.sidebar-collapsed .sidebar .session-list,
    body.sidebar-collapsed .sidebar .muted,
    body.sidebar-collapsed .sidebar .panel-label,
    body.properties-collapsed .properties-drawer .properties-body,
    body.properties-collapsed .properties-drawer .muted,
    body.properties-collapsed .properties-drawer #properties-title {
      display: none;
    }
    body.sidebar-collapsed .sidebar .panel-title,
    body.properties-collapsed .properties-drawer .panel-title {
      position: relative;
      display: block;
      min-height: 168px;
      padding: 0;
      border-bottom: 0;
      background: transparent;
      overflow: visible;
    }
    body.sidebar-collapsed .sidebar .panel-title .pixel-button,
    body.properties-collapsed .properties-drawer .panel-title .pixel-button {
      position: absolute;
      top: 134px;
      width: 134px;
      height: 46px;
      min-height: 0;
      display: flex;
      align-items: center;
      background: var(--surface-strong);
      box-shadow: none;
      padding: 0 12px;
      white-space: nowrap;
    }
    body.sidebar-collapsed .sidebar .panel-title .pixel-button {
      left: 0;
      justify-content: flex-start;
      text-align: left;
      transform: rotate(-90deg);
      transform-origin: left top;
    }
    body.properties-collapsed .properties-drawer .panel-title .pixel-button {
      right: 0;
      justify-content: flex-end;
      text-align: right;
      transform: rotate(90deg);
      transform-origin: right top;
    }
    .session-list {
      min-height: 0;
      overflow: auto;
      padding: 9px;
      display: grid;
      align-content: start;
      gap: 8px;
      grid-row: 2;
    }
    .flow-manager {
      min-height: 0;
      padding: 9px;
      display: grid;
      grid-template-rows: minmax(150px, 44%) minmax(130px, 1fr);
      gap: 8px;
      grid-row: 2;
    }
    .flow-manager .session-list {
      padding: 0;
      grid-row: auto;
    }
    .flow-manager-trace {
      min-height: 0;
      overflow: hidden;
      display: grid;
      grid-template-rows: auto minmax(0, 1fr);
      gap: 8px;
      margin-top: 0;
      padding-top: 0;
    }
    .flow-manager-trace .workflow-panel {
      margin-top: 0 !important;
      padding-top: 14px !important;
      border-top: 3px solid var(--border) !important;
    }
    .flow-manager-trace > .group-label {
      width: fit-content;
      border: 2px solid var(--border);
      background: var(--accent);
      color: #111;
      box-shadow: 3px 3px 0 var(--shadow);
      padding: 3px 8px;
    }
    .sidebar-body {
      min-height: 0;
      display: grid;
      grid-template-rows: auto minmax(0, 1fr);
    }
    .sidebar-tabs {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 6px;
      padding: 8px 9px 0;
    }
    .sidebar-tab {
      border: 2px solid var(--border);
      background: var(--surface-strong);
      color: var(--ink);
      padding: 5px 6px;
      font-size: 12px;
      font-weight: 850;
      cursor: pointer;
      box-shadow: 2px 2px 0 var(--surface-muted);
    }
    .sidebar-tab.active {
      background: var(--accent);
      color: #111;
      box-shadow: 2px 2px 0 var(--shadow);
    }
    .session-card {
      width: 100%;
      border: 2px solid var(--border);
      border-radius: 0;
      padding: 10px;
      background: var(--surface-strong);
      text-align: left;
      cursor: pointer;
      box-shadow: 3px 3px 0 var(--surface-muted);
    }
    .session-card:hover, .session-card.selected { background: #eefbff; }
    body[data-theme="dark"] .session-card:hover,
    body[data-theme="dark"] .session-card.selected { background: #17323a; }
    .session-card.selected { outline: 3px solid var(--accent-2); }
    .session-card strong {
      display: block;
      font-size: 13px;
      overflow-wrap: anywhere;
    }
    .meta {
      margin-top: 4px;
      color: var(--muted);
      font-size: 12px;
      overflow-wrap: anywhere;
    }
    .status {
      display: inline-flex;
      align-items: center;
      min-height: 22px;
      padding: 0 8px;
      border: 2px solid var(--border);
      background: var(--stopped);
      color: #fff;
      font-size: 12px;
      font-weight: 850;
      margin-top: 8px;
      text-transform: lowercase;
    }
    .status.succeeded { background: var(--success); }
    .status.failed { background: var(--failed); }
    .status.running { background: var(--running); }
    .status.interrupted { background: var(--stopped); }
    .workbench {
      min-height: 0;
      display: grid;
      grid-template-rows: var(--chat-panel-height, minmax(320px, 1fr)) 8px minmax(0, 1fr);
      gap: 4px;
    }
    .room-panel {
      display: grid;
      grid-template-rows: auto minmax(0, 1fr);
    }
    .room-title-main {
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .room-title-actions {
      display: inline-flex;
      align-items: center;
      gap: 8px;
    }
    .hash-tile {
      display: inline-grid;
      place-items: center;
      width: 28px;
      height: 28px;
      border: 2px solid var(--border);
      background: var(--accent);
      color: #111;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-weight: 900;
    }
    .chat-room {
      min-height: 0;
      overflow: auto;
      padding: 14px;
      display: grid;
      align-content: start;
      gap: 12px;
      background:
        linear-gradient(90deg, rgba(0,0,0,.035) 1px, transparent 1px),
        linear-gradient(rgba(0,0,0,.035) 1px, transparent 1px),
        var(--surface);
      background-size: 18px 18px;
    }
    body[data-theme="dark"] .chat-room {
      background:
        linear-gradient(90deg, rgba(255,255,255,.045) 1px, transparent 1px),
        linear-gradient(rgba(255,255,255,.045) 1px, transparent 1px),
        var(--surface);
      background-size: 18px 18px;
    }
    .chat-event {
      display: grid;
      grid-template-columns: 38px minmax(0, 1fr);
      gap: 9px;
      align-items: start;
      max-width: 980px;
    }
    .chat-event.user {
      grid-template-columns: minmax(0, 1fr) 38px;
      justify-self: end;
    }
    .chat-event.user-system {
      grid-template-columns: minmax(0, 1fr) 38px;
      justify-self: end;
      margin-right: 46px;
      max-width: 760px;
    }
    .chat-event.user .avatar {
      grid-column: 2;
      grid-row: 1;
      background: var(--accent-2);
      color: #111;
    }
    .chat-event.user-system .avatar {
      grid-column: 2;
      grid-row: 1;
    }
    .chat-event.user .chat-bubble {
      grid-column: 1;
      grid-row: 1;
      background: #eefbff;
    }
    .chat-event.user-system .chat-bubble {
      grid-column: 1;
      grid-row: 1;
      background: #fff3c7;
    }
    body[data-theme="dark"] .chat-event.user .chat-bubble {
      background: #17323a;
    }
    body[data-theme="dark"] .chat-event.user-system .chat-bubble {
      background: #3d3320;
    }
    .chat-event.user .chat-head {
      justify-content: flex-end;
    }
    .chat-event.user-system .chat-head {
      justify-content: flex-end;
    }
    .chat-event.user .chat-text {
      text-align: left;
    }
    .chat-event.system { max-width: 760px; margin-left: 46px; }
    .avatar {
      width: 34px;
      height: 34px;
      display: grid;
      place-items: center;
      border: 3px solid var(--border);
      background: var(--accent);
      color: #111;
      box-shadow: 2px 2px 0 var(--shadow);
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-weight: 900;
      text-transform: uppercase;
    }
    .chat-bubble {
      min-width: 0;
      border: 2px solid var(--border);
      background: var(--surface-strong);
      box-shadow: 3px 3px 0 var(--surface-muted);
      padding: 9px 10px;
    }
    .chat-event.system .chat-bubble { background: #fff3c7; }
    body[data-theme="dark"] .chat-event.system .chat-bubble { background: #3d3320; }
    .chat-head {
      display: flex;
      align-items: baseline;
      gap: 8px;
      margin-bottom: 4px;
      font-size: 12px;
    }
    .chat-author { font-weight: 850; }
    .chat-target { color: var(--accent-2); font-weight: 850; }
    .chat-text {
      font-size: 13px;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
    }
    .message-toggle {
      margin-top: 8px;
      border: 2px solid var(--border);
      background: var(--accent);
      color: #111;
      padding: 2px 7px;
      font-size: 12px;
      font-weight: 850;
      cursor: pointer;
    }
    .flow-map {
      min-height: 100%;
      display: grid;
      align-content: start;
      gap: 14px;
    }
    .flow-workspace {
      min-height: 100%;
      display: block;
    }
    .flow-graph-view,
    .flow-trace-view {
      min-height: 0;
      border: 2px solid var(--border);
      background: rgba(255,255,255,.02);
      box-shadow: 3px 3px 0 var(--surface-muted);
      overflow: auto;
      padding: 12px;
    }
    .flow-map-head {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: 10px;
      border: 2px solid var(--border);
      background: var(--surface-strong);
      box-shadow: 3px 3px 0 var(--surface-muted);
      padding: 10px;
      font-size: 13px;
    }
    .flow-sequence,
    .flow-loop-body {
      display: grid;
      gap: 12px;
      min-width: 0;
      margin-top: 16px;
    }
    .flow-sequence {
      grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
      align-items: start;
    }
    .flow-loop {
      border: 2px solid var(--accent);
      background: color-mix(in srgb, var(--accent) 10%, var(--surface));
      box-shadow: 3px 3px 0 var(--surface-muted);
      padding: 10px;
      min-width: 0;
      grid-column: 1 / -1;
    }
    .flow-loop-head {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: 12px;
      border-bottom: 2px solid var(--border);
      padding-bottom: 7px;
      font-size: 12px;
      font-weight: 900;
    }
    .flow-loop-body {
      grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
      margin-top: 10px;
    }
    .flow-projection-node {
      min-width: 0;
      border-left-width: 7px;
    }
    .flow-projection-node.completed { border-left-color: var(--success); }
    .flow-projection-node.running { border-left-color: var(--running); }
    .flow-projection-node.pending { border-left-color: var(--stopped); }
    .flow-projection-node.failed { border-left-color: var(--failed); }
    .flow-branch {
      min-width: 0;
    }
    .flow-branch-cases {
      display: grid;
      gap: 4px;
      margin-top: 6px;
    }
    .flow-branch-case {
      display: grid;
      grid-template-columns: minmax(58px, auto) minmax(0, 1fr);
      gap: 6px;
      border-top: 1px solid color-mix(in srgb, var(--border) 28%, transparent);
      padding-top: 4px;
      font-size: 12px;
    }
    .flow-edge {
      color: var(--accent);
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-weight: 900;
      white-space: nowrap;
    }
    .flow-node-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 22px 18px;
      align-items: start;
    }
    .flow-node {
      position: relative;
      border: 2px solid var(--border);
      background: var(--surface-strong);
      box-shadow: 3px 3px 0 var(--surface-muted);
      padding: 9px;
      min-height: 86px;
    }
    .flow-node.primary {
      min-width: 260px;
      border-color: var(--accent);
    }
    .flow-node.child {
      min-width: 210px;
    }
    .flow-node-grid .flow-node:not(:last-child)::after {
      content: ">";
      position: absolute;
      right: -17px;
      top: 30px;
      color: var(--accent);
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-weight: 900;
    }
    .flow-node-title {
      font-weight: 900;
      overflow-wrap: anywhere;
    }
    .flow-trace-scroller {
      min-height: 0;
      overflow: auto;
      display: grid;
      align-content: start;
      gap: 8px;
    }
    .flow-trace-card {
      border: 2px solid var(--border);
      background: var(--surface-strong);
      box-shadow: 3px 3px 0 var(--surface-muted);
      padding: 8px;
      overflow-wrap: anywhere;
    }
    .flow-trace-card.workflow { border-left-color: var(--accent); }
    .flow-trace-card.agent { border-left-color: var(--running); }
    .flow-trace-card.artifact { border-left-color: var(--success); }
    .flow-trace-card.board,
    .flow-trace-card.transform { border-left-color: var(--accent-3); }
    .flow-trace-card.vertex,
    .flow-trace-card.script { border-left-color: var(--accent-2); }
    .flow-trace-kicker {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      color: var(--muted);
      font-size: 11px;
      margin-bottom: 4px;
    }
    .trace-kind {
      border: 2px solid var(--border);
      background: var(--surface);
      color: var(--ink);
      padding: 1px 5px;
      font-weight: 900;
    }
    .flow-trace-title {
      color: var(--ink);
      font-weight: 900;
      margin-bottom: 6px;
      font-size: 13px;
    }
    .trace-detail-grid {
      display: grid;
      grid-template-columns: minmax(76px, 34%) minmax(0, 1fr);
      gap: 4px 8px;
      margin: 0;
    }
    .trace-detail-grid dt {
      color: var(--muted);
      font-weight: 850;
      font-size: 12px;
      margin: 0;
      overflow-wrap: anywhere;
    }
    .trace-detail-grid dd {
      color: var(--ink);
      margin: 0;
      font-size: 12px;
    }
    .trace-empty {
      color: var(--muted);
      font-style: italic;
    }
    .flow-node-meta {
      margin-top: 4px;
      color: var(--muted);
      font-size: 12px;
      overflow-wrap: anywhere;
    }
    .flow-node-inputs {
      display: grid;
      gap: 3px;
      margin-top: 7px;
      font-size: 11px;
    }
    .flow-node-input {
      display: grid;
      grid-template-columns: minmax(42px, auto) minmax(0, 1fr);
      gap: 6px;
      border-top: 1px solid color-mix(in srgb, var(--border) 22%, transparent);
      padding-top: 3px;
      color: var(--muted);
      min-width: 0;
    }
    .flow-node-input strong {
      color: var(--ink);
      font-weight: 900;
    }
    .flow-node-input span {
      overflow-wrap: anywhere;
      min-width: 0;
    }
    .details-stack {
      min-height: 0;
      display: grid;
      grid-template-rows: minmax(120px, var(--timeline-panel-height, min(24vh, 280px))) 8px minmax(0, 1fr);
      align-content: start;
      gap: 4px;
    }
    .fold-panel {
      border: 3px solid var(--border);
      background: var(--surface);
      box-shadow: 4px 4px 0 var(--shadow);
      min-width: 0;
      min-height: 0;
      overflow: hidden;
    }
    .timeline-panel[open] {
      display: grid;
      grid-template-rows: auto minmax(0, 1fr);
      min-height: 0;
    }
    .fold-panel > summary {
      min-height: 38px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 10px;
      padding: 7px 10px;
      border-bottom: 3px solid var(--border);
      background: var(--surface-strong);
      cursor: default;
      font-weight: 850;
      list-style: none;
    }
    .fold-panel:not([open]) > summary {
      border-bottom: 0;
    }
    .fold-panel > summary::-webkit-details-marker { display: none; }
    .fold-summary-actions {
      display: inline-flex;
      align-items: center;
      justify-content: flex-end;
      gap: 10px;
      min-width: 0;
    }
    .properties-body {
      min-height: 0;
      overflow: auto;
      padding: 10px;
    }
    .properties-drawer {
      min-width: 0;
    }
    .properties-drawer .properties-body {
      padding: 10px;
    }
    .properties-drawer .session-dashboard {
      align-content: start;
    }
    .properties-drawer .property-groups,
    .properties-drawer .metric-strip {
      grid-template-columns: 1fr;
    }
    .properties-drawer .token-row {
      grid-template-columns: 74px minmax(0, 1fr) 74px;
    }
    .workflow-panel {
      display: grid;
      gap: 8px;
      margin-top: 18px;
      padding-top: 14px;
      border-top: 3px solid var(--border);
    }
    .workflow-panel > .group-label {
      width: fit-content;
      border: 2px solid var(--border);
      background: var(--accent);
      color: #111;
      box-shadow: 3px 3px 0 var(--shadow);
      padding: 3px 8px;
    }
    .workflow-card,
    .workflow-view-slot {
      border: 2px solid var(--border);
      background: var(--surface-strong);
      box-shadow: 3px 3px 0 var(--surface-muted);
      padding: 8px;
      overflow-wrap: anywhere;
    }
    .workflow-rendered-view {
      display: grid;
      gap: 8px;
      margin-top: 8px;
      font-size: 12px;
    }
    .workflow-rendered-view section,
    .workflow-rendered-view article,
    .workflow-rendered-view div {
      display: grid;
      gap: 6px;
    }
    .workflow-rendered-view h1,
    .workflow-rendered-view h2,
    .workflow-rendered-view h3,
    .workflow-rendered-view h4,
    .workflow-rendered-view p,
    .workflow-rendered-view ul,
    .workflow-rendered-view ol,
    .workflow-rendered-view dl {
      margin: 0;
    }
    .workflow-rendered-view h3 {
      font-size: 14px;
      font-weight: 900;
    }
    .workflow-rendered-view table {
      width: 100%;
      border-collapse: collapse;
      font-size: 12px;
    }
    .workflow-rendered-view th,
    .workflow-rendered-view td {
      border-top: 1px solid color-mix(in srgb, var(--border) 28%, transparent);
      padding: 4px 0;
      text-align: left;
      vertical-align: top;
    }
    .workflow-rendered-view code,
    .workflow-rendered-view pre {
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      white-space: pre-wrap;
    }
    .session-dashboard {
      display: grid;
      gap: 10px;
    }
    .session-summary {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 12px;
      align-items: start;
      border: 2px solid var(--border);
      background: var(--surface-strong);
      box-shadow: 3px 3px 0 var(--surface-muted);
      padding: 10px;
    }
    .session-summary .status {
      margin-top: 0;
      align-self: start;
    }
    .summary-label,
    .group-label,
    .metric-label,
    .property-label {
      color: var(--muted);
      font-size: 11px;
      font-weight: 850;
    }
    .summary-value {
      margin-top: 4px;
      font-size: 16px;
      font-weight: 900;
      overflow-wrap: anywhere;
    }
    .property-groups {
      display: grid;
      grid-template-columns: minmax(0, 1.2fr) minmax(0, .8fr);
      gap: 8px;
    }
    .property-group {
      min-width: 0;
      border: 2px solid var(--border);
      background: var(--surface-muted);
      padding: 9px;
    }
    .property-group.identity {
      background:
        linear-gradient(90deg, rgba(26,138,158,.14), transparent 70%),
        var(--surface-muted);
    }
    .property-lines {
      display: grid;
      gap: 7px;
      margin-top: 4px;
    }
    .property-line {
      display: grid;
      grid-template-columns: 100px minmax(0, 1fr);
      gap: 8px;
      align-items: baseline;
      border-top: 1px solid rgba(0,0,0,.14);
      padding-top: 6px;
    }
    body[data-theme="dark"] .property-line { border-top-color: rgba(255,255,255,.16); }
    .property-value {
      font-size: 12px;
      overflow-wrap: anywhere;
    }
    .metric-strip {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 8px;
    }
    .metric-tile {
      min-width: 0;
      border: 2px solid var(--border);
      background: var(--surface-strong);
      padding: 8px;
      box-shadow: 3px 3px 0 var(--surface-muted);
    }
    .metric-value {
      margin-top: 5px;
      font-size: 15px;
      font-weight: 900;
      overflow-wrap: anywhere;
    }
    .token-board {
      display: grid;
      gap: 8px;
      margin-top: 8px;
    }
    .token-row {
      display: grid;
      grid-template-columns: 96px minmax(0, 1fr) 90px;
      gap: 8px;
      align-items: center;
      font-size: 12px;
    }
    .token-track {
      height: 14px;
      border: 2px solid var(--border);
      background: var(--surface-strong);
      overflow: hidden;
    }
    .token-fill {
      height: 100%;
      min-width: 3px;
      background: var(--accent-2);
    }
    .token-fill.empty { min-width: 0; }
    .token-fill.cached { background: var(--accent-3); }
    .token-fill.output { background: var(--success); }
    .token-fill.reasoning { background: var(--running); }
    .transcript-shell {
      height: 100%;
      min-height: 0;
      display: grid;
      grid-template-rows: minmax(0, 1fr);
    }
    .transcript-panel[open] {
      display: grid;
      grid-template-rows: auto minmax(0, 1fr);
      min-height: 0;
    }
    .follow-control {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      color: var(--muted);
      font-size: 12px;
      font-weight: 750;
      user-select: none;
    }
    .transcript-view {
      min-height: 0;
      overflow: auto;
      overflow-y: scroll;
      scrollbar-gutter: stable;
      background: var(--terminal);
      color: var(--terminal-text);
      padding: 12px;
      font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
    }
    .transcript {
      display: grid;
      gap: 9px;
    }
    .transcript.codex .transcript-entry.tool {
      border-left-color: #48b3ff;
    }
    .transcript.claude .transcript-entry.tool {
      border-left-color: #d77757;
    }
    .transcript-entry {
      border-left: 4px solid #607080;
      padding: 4px 0 4px 10px;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
    }
    .transcript-entry.input { border-left-color: var(--accent); background: rgba(255, 211, 61, .08); }
    .transcript-entry.output { border-left-color: #60d394; }
    .transcript-entry.log { color: #b8c5cf; }
    .transcript-entry.error { border-left-color: var(--failed); color: #ffb3ad; }
    .transcript-kicker {
      color: #9fb0bc;
      font-weight: 850;
      margin-bottom: 2px;
    }
    .timeline-content {
      min-height: 0;
      overflow: auto;
      scrollbar-gutter: stable;
      padding: 10px;
    }
    .gantt {
      display: grid;
      gap: 10px;
      align-content: start;
      min-width: 0;
    }
    .gantt-row {
      display: grid;
      grid-template-columns: minmax(120px, 165px) minmax(120px, 1fr);
      grid-template-areas:
        "label track"
        "label stat";
      gap: 3px 8px;
      align-items: center;
      min-height: 30px;
    }
    .gantt-label {
      grid-area: label;
      color: var(--muted);
      font-size: 12px;
      overflow-wrap: anywhere;
    }
    .gantt-label strong {
      display: block;
      color: var(--ink);
      font-size: 12px;
    }
    .track {
      grid-area: track;
      position: relative;
      height: 26px;
      border: 2px solid var(--border);
      background: var(--surface-muted);
      overflow: hidden;
    }
    .segment {
      position: absolute;
      top: 3px;
      height: 16px;
      min-width: 4px;
      background: var(--accent-2);
    }
    .segment.succeeded { background: var(--success); }
    .segment.failed { background: var(--failed); }
    .segment.running { background: var(--running); }
    .segment.interrupted { background: var(--stopped); }
    .segment.selected { outline: 3px solid var(--accent-3); outline-offset: 1px; }
    .gantt-stat {
      grid-area: stat;
      text-align: left;
      color: var(--ink);
      font-size: 12px;
      font-weight: 750;
      white-space: normal;
    }
    .empty {
      padding: 20px;
      color: var(--muted);
      font-size: 13px;
    }
    @media (max-width: 1180px) {
      body { min-width: 0; }
      .dashboard-shell,
      body.sidebar-collapsed .dashboard-shell,
      body.properties-collapsed .dashboard-shell,
      body.sidebar-collapsed.properties-collapsed .dashboard-shell {
        grid-template-columns: 1fr;
        height: auto;
      }
      .layout-resizer,
      .stack-resizer {
        display: none;
      }
      .sidebar,
      .workbench,
      .properties-drawer {
        grid-column: auto;
      }
      .sidebar, .properties-drawer { min-height: 260px; }
      .workbench { grid-template-rows: minmax(420px, 60vh) auto; }
      .details-stack { grid-template-rows: auto auto; }
      .property-groups,
      .metric-strip { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body data-theme="${defaultTheme}">
  <header class="topbar">
    ${brandHeaderHtml(appVersion)}
    <div class="top-actions">
      <button class="pixel-button all-panels-toggle" type="button" id="all-panels-toggle" aria-pressed="false">Hide All</button>
      <button class="pixel-button" type="button" id="theme-toggle" aria-pressed="false">Dark</button>
    </div>
  </header>
  <main class="dashboard-shell">
    <aside class="panel sidebar" id="sidebar-panel">
      <div class="panel-title">
        <span class="panel-label">Agent Sessions</span>
        <span class="muted" id="session-count"></span>
        <button class="pixel-button" type="button" id="sidebar-toggle" aria-expanded="true">Hide</button>
      </div>
      <div class="sidebar-body">
        <div class="sidebar-tabs" role="tablist" aria-label="Sidebar view">
          <button class="sidebar-tab active" type="button" id="sessions-tab" aria-selected="true">Sessions</button>
          <button class="sidebar-tab" type="button" id="flows-tab" aria-selected="false">Flow Manager</button>
        </div>
        <div class="session-list" id="session-list"></div>
        <div class="flow-manager" id="flow-manager" hidden>
          <div class="session-list" id="flow-list"></div>
          <section class="flow-manager-trace" id="flow-manager-trace"></section>
        </div>
      </div>
    </aside>
    <div class="layout-resizer sidebar-resizer" data-resize="sidebar-width" role="separator" aria-orientation="vertical" aria-label="Resize agent sessions"></div>
    <section class="workbench">
      <section class="panel room-panel">
        <div class="panel-title">
          <div class="room-title-main"><span class="hash-tile">#</span><span>Group Chat</span></div>
          <span class="room-title-actions">
            <button class="pixel-button" type="button" id="flow-view-toggle" aria-pressed="false">Flow View</button>
            <span class="muted" id="updated-at"></span>
          </span>
        </div>
        <div class="chat-room" id="group-chat"></div>
      </section>
      <div class="stack-resizer chat-resizer" data-resize="chat-height" role="separator" aria-orientation="horizontal" aria-label="Resize group chat"></div>
      <section class="details-stack">
        <details class="fold-panel timeline-panel" id="timeline-panel" open>
          <summary data-fold-summary="timeline">
            <span>Timeline</span>
            <button class="pixel-button" type="button" id="timeline-toggle" aria-expanded="true">Hide</button>
          </summary>
          <div class="timeline-content" id="gantt"></div>
        </details>
        <div class="stack-resizer timeline-resizer" data-resize="timeline-transcript-height" role="separator" aria-orientation="horizontal" aria-label="Resize timeline and transcript"></div>
        <details class="fold-panel transcript-panel" id="transcript-panel" open>
          <summary data-fold-summary="transcript">
            <span>Session Transcript</span>
            <span class="fold-summary-actions">
              <label class="follow-control"><input type="checkbox" id="follow-output" checked> Follow live output</label>
              <button class="pixel-button" type="button" id="transcript-toggle" aria-expanded="true">Hide</button>
            </span>
          </summary>
          <div class="transcript-shell">
            <div class="transcript-view" id="session-transcript"></div>
          </div>
        </details>
      </section>
    </section>
    <div class="layout-resizer properties-resizer" data-resize="properties-width" role="separator" aria-orientation="vertical" aria-label="Resize session properties"></div>
    <aside class="panel properties-drawer" id="properties-panel">
      <div class="panel-title">
        <span id="properties-title">Session Properties</span>
        <button class="pixel-button" type="button" id="properties-toggle" aria-expanded="true">Hide</button>
      </div>
      <div class="properties-body" id="detail-header"></div>
    </aside>
  </main>
  <script>
    const configuredDefaultTheme = "${defaultTheme}";
    const sessionListElement = document.getElementById("session-list");
    const flowListElement = document.getElementById("flow-list");
    const flowManagerElement = document.getElementById("flow-manager");
    const flowManagerTraceElement = document.getElementById("flow-manager-trace");
    const sessionsTabElement = document.getElementById("sessions-tab");
    const flowsTabElement = document.getElementById("flows-tab");
    const sessionCountElement = document.getElementById("session-count");
    const groupChatElement = document.getElementById("group-chat");
    const flowViewToggleElement = document.getElementById("flow-view-toggle");
    const ganttElement = document.getElementById("gantt");
    const updatedAtElement = document.getElementById("updated-at");
    const detailHeaderElement = document.getElementById("detail-header");
    const propertiesTitleElement = document.getElementById("properties-title");
    const transcriptElement = document.getElementById("session-transcript");
    const followOutputElement = document.getElementById("follow-output");
    const themeToggleElement = document.getElementById("theme-toggle");
    const allPanelsToggleElement = document.getElementById("all-panels-toggle");
    const sidebarToggleElement = document.getElementById("sidebar-toggle");
    const propertiesToggleElement = document.getElementById("properties-toggle");
    const timelineToggleElement = document.getElementById("timeline-toggle");
    const transcriptToggleElement = document.getElementById("transcript-toggle");
    const dashboardShellElement = document.querySelector(".dashboard-shell");
    const workbenchElement = document.querySelector(".workbench");
    const roomPanelElement = document.querySelector(".room-panel");
    const chatResizerElement = document.querySelector(".chat-resizer");
    const timelinePanelElement = document.getElementById("timeline-panel");
    const transcriptPanelElement = document.getElementById("transcript-panel");
    const transcriptShellElement = document.querySelector(".transcript-shell");
    const resizeHandles = document.querySelectorAll("[data-resize]");
    const expandedMessages = new Set();
    let selectedSessionId = null;
    let selectedWorkflowId = null;
    let sidebarMode = "sessions";
    let roomMode = "chat";
    let lastAgentSessions = [];
    let lastHubSessions = [];
    let lastWorkflowRuns = [];

    initializeUiState();

    async function refresh() {
      const [agentSessionsResponse, hubSessionsResponse, workflowsResponse] = await Promise.all([
        fetch("/api/agent-sessions"),
        fetch("/api/sessions"),
        fetch("/api/workflows")
      ]);
      const agentSessionsPayload = await agentSessionsResponse.json();
      const hubSessionsPayload = await hubSessionsResponse.json();
      const workflowsPayload = await workflowsResponse.json();
      lastAgentSessions = agentSessionsPayload.agentSessions || [];
      lastHubSessions = hubSessionsPayload.sessions || [];
      lastWorkflowRuns = workflowsPayload.workflows || [];
      selectedSessionId = nextSelectedSessionId(selectedSessionId, lastAgentSessions);
      selectedWorkflowId = nextSelectedWorkflowId(selectedWorkflowId, lastWorkflowRuns);
      renderSessionList(lastAgentSessions);
      renderFlowList(lastWorkflowRuns);
      renderFlowManagerTrace(lastWorkflowRuns);
      renderSidebarMode();
      const context = contextSessions(lastAgentSessions);
      renderRoom(context);
      renderGantt(context);
      renderSelectedSession();
      updatedAtElement.textContent = new Date().toLocaleTimeString();
    }

    function initializeUiState() {
      setTheme(normalizeTheme(localStorage.getItem("h2-theme") || configuredDefaultTheme));
      sidebarMode = localStorage.getItem("h2-sidebar-mode") === "flows" ? "flows" : "sessions";
      roomMode = localStorage.getItem("h2-room-mode") === "flow" ? "flow" : "chat";
      setSidebarCollapsed(localStorage.getItem("h2-sidebar-collapsed") === "true");
      setPropertiesCollapsed(localStorage.getItem("h2-properties-collapsed") === "true");
      setRoomMode(roomMode);
      setFoldPanelCollapsed(timelinePanelElement, timelineToggleElement, "timeline", localStorage.getItem("h2-timeline-collapsed") === "true");
      setFoldPanelCollapsed(transcriptPanelElement, transcriptToggleElement, "transcript", localStorage.getItem("h2-transcript-collapsed") === "true");
      updateAllPanelsToggle();
      preventSummaryToggle(timelinePanelElement);
      preventSummaryToggle(transcriptPanelElement);
      initResizableLayout();
      themeToggleElement.addEventListener("click", () => {
        setTheme(document.body.dataset.theme === "dark" ? "light" : "dark");
      });
      allPanelsToggleElement.addEventListener("click", () => {
        setAllPanelsCollapsed(!areAllPanelsCollapsed());
      });
      sidebarToggleElement.addEventListener("click", () => {
        setSidebarCollapsed(!document.body.classList.contains("sidebar-collapsed"));
      });
      sessionsTabElement.addEventListener("click", () => {
        setSidebarMode("sessions");
      });
      flowsTabElement.addEventListener("click", () => {
        setSidebarMode("flows");
      });
      flowViewToggleElement.addEventListener("click", () => {
        setRoomMode(roomMode === "flow" ? "chat" : "flow");
      });
      propertiesToggleElement.addEventListener("click", () => {
        setPropertiesCollapsed(!document.body.classList.contains("properties-collapsed"));
      });
      timelineToggleElement.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        setFoldPanelCollapsed(timelinePanelElement, timelineToggleElement, "timeline", timelinePanelElement.open);
      });
      transcriptToggleElement.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        setFoldPanelCollapsed(transcriptPanelElement, transcriptToggleElement, "transcript", transcriptPanelElement.open);
      });
      groupChatElement.addEventListener("click", (event) => {
        if (!(event.target instanceof Element)) {
          return;
        }
        const button = event.target.closest("[data-message-toggle]");
        if (button === null) {
          return;
        }
        toggleLongMessage(button.getAttribute("data-message-toggle"));
      });
    }

    function initResizableLayout() {
      restoreLayoutValue("h2-layout-sidebar-width", "--sidebar-width", 260, 620);
      restoreLayoutValue("h2-layout-properties-width", "--properties-width", 280, 620);
      restoreLayoutValue("h2-layout-chat-height", "--chat-panel-height", 220, 900);
      restoreLayoutValue("h2-layout-timeline-height", "--timeline-panel-height", 120, 700);
      restoreLayoutValue("h2-layout-transcript-height", "--transcript-panel-height", 180, 900);
      clampChatHeightToCurrentBounds();
      for (const handle of resizeHandles) {
        handle.addEventListener("pointerdown", (event) => startLayoutResize(event, handle.getAttribute("data-resize")));
      }
    }

    function restoreLayoutValue(key, variableName, min, max) {
      const value = Number.parseFloat(localStorage.getItem(key) || "");
      if (Number.isFinite(value)) {
        document.documentElement.style.setProperty(variableName, clamp(value, min, max) + "px");
      }
    }

    function startLayoutResize(event, kind) {
      if (kind === null) {
        return;
      }
      event.preventDefault();
      if (typeof event.currentTarget.setPointerCapture === "function") {
        try {
          event.currentTarget.setPointerCapture(event.pointerId);
        } catch {
          // Synthetic pointer events used by browser checks may not have an active pointer.
        }
      }
      document.body.classList.add("layout-resizing");
      const state = {
        kind,
        pointerId: event.pointerId,
        startX: event.clientX,
        startY: event.clientY,
        sidebarWidth: rectWidth(document.querySelector(".sidebar")),
        propertiesWidth: rectWidth(document.querySelector(".properties-drawer")),
        chatHeight: rectHeight(roomPanelElement),
        timelineHeight: rectHeight(timelinePanelElement),
        transcriptHeight: rectHeight(transcriptPanelElement)
      };
      const onMove = (moveEvent) => updateLayoutResize(moveEvent, state);
      const onDone = () => {
        document.body.classList.remove("layout-resizing");
        window.removeEventListener("pointermove", onMove);
        window.removeEventListener("pointerup", onDone);
        window.removeEventListener("pointercancel", onDone);
      };
      window.addEventListener("pointermove", onMove);
      window.addEventListener("pointerup", onDone, { once: true });
      window.addEventListener("pointercancel", onDone, { once: true });
    }

    function updateLayoutResize(event, state) {
      if (state.kind === "sidebar-width") {
        setLayoutSize("h2-layout-sidebar-width", "--sidebar-width", state.sidebarWidth + event.clientX - state.startX, 260, 620);
      } else if (state.kind === "properties-width") {
        setLayoutSize("h2-layout-properties-width", "--properties-width", state.propertiesWidth - (event.clientX - state.startX), 280, 620);
      } else if (state.kind === "chat-height") {
        resizeChatBoundary(event, state);
      } else if (state.kind === "timeline-transcript-height") {
        const delta = event.clientY - state.startY;
        setLayoutSize("h2-layout-timeline-height", "--timeline-panel-height", state.timelineHeight + delta, 120, 700);
        setLayoutSize("h2-layout-transcript-height", "--transcript-panel-height", state.transcriptHeight - delta, 180, 900);
      }
    }

    function setLayoutSize(key, variableName, value, min, max) {
      const next = clamp(value, min, max);
      document.documentElement.style.setProperty(variableName, next + "px");
      localStorage.setItem(key, String(Math.round(next)));
    }

    function resizeChatBoundary(event, state) {
      const bounds = chatResizeBounds();
      if (bounds === null) {
        return;
      }
      setLayoutSize("h2-layout-chat-height", "--chat-panel-height", state.chatHeight + event.clientY - state.startY, bounds.min, bounds.max);
    }

    function chatResizeBounds() {
      if (document.body.classList.contains("timeline-collapsed") && document.body.classList.contains("transcript-collapsed")) {
        return null;
      }
      const workbenchHeight = rectHeight(workbenchElement);
      const gapHeight = 8;
      const dividerHeight = Math.max(0, rectHeight(chatResizerElement));
      const min = visiblePanelMinimumHeight();
      const max = Math.max(min, workbenchHeight - dividerHeight - gapHeight - detailsMinimumHeight());
      return { min, max };
    }

    function detailsMinimumHeight() {
      const timelineCollapsed = document.body.classList.contains("timeline-collapsed");
      const transcriptCollapsed = document.body.classList.contains("transcript-collapsed");
      const foldedTimelineHeight = foldedPanelHeight(timelinePanelElement);
      const foldedTranscriptHeight = foldedPanelHeight(transcriptPanelElement);
      const visibleHeight = visiblePanelMinimumHeight();

      if (timelineCollapsed && transcriptCollapsed) {
        return foldedTimelineHeight + foldedTranscriptHeight + 8;
      }
      if (timelineCollapsed) {
        return foldedTimelineHeight + visibleHeight + 8;
      }
      if (transcriptCollapsed) {
        return visibleHeight + foldedTranscriptHeight + 8;
      }
      return visibleHeight + visibleHeight + 16;
    }

    function visiblePanelMinimumHeight() {
      return 96;
    }

    function foldedPanelHeight(panel) {
      if (panel === null) {
        return 52;
      }
      const summary = panel.querySelector("summary");
      return Math.max(52, rectHeight(summary) + 14);
    }

    function clampChatHeightToCurrentBounds() {
      const bounds = chatResizeBounds();
      if (bounds === null) {
        return;
      }
      const current = cssLengthValue("--chat-panel-height", rectHeight(roomPanelElement));
      setLayoutSize("h2-layout-chat-height", "--chat-panel-height", current, bounds.min, bounds.max);
    }

    function cssLengthValue(variableName, fallback) {
      const value = Number.parseFloat(getComputedStyle(document.documentElement).getPropertyValue(variableName));
      return Number.isFinite(value) ? value : fallback;
    }

    function rectWidth(element) {
      return element === null ? 0 : element.getBoundingClientRect().width;
    }

    function rectHeight(element) {
      return element === null ? 0 : element.getBoundingClientRect().height;
    }

    function clamp(value, min, max) {
      return Math.min(max, Math.max(min, value));
    }

    function setTheme(theme) {
      const nextTheme = normalizeTheme(theme);
      document.body.dataset.theme = nextTheme;
      localStorage.setItem("h2-theme", nextTheme);
      themeToggleElement.textContent = nextTheme === "dark" ? "Light" : "Dark";
      themeToggleElement.setAttribute("aria-pressed", nextTheme === "dark" ? "true" : "false");
    }

    function normalizeTheme(theme) {
      return theme === "light" ? "light" : "dark";
    }

    function setSidebarCollapsed(collapsed) {
      document.body.classList.toggle("sidebar-collapsed", collapsed);
      localStorage.setItem("h2-sidebar-collapsed", String(collapsed));
      sidebarToggleElement.textContent = collapsed ? "Sessions" : "Hide";
      sidebarToggleElement.setAttribute("aria-expanded", collapsed ? "false" : "true");
      updateAllPanelsToggle();
    }

    function setPropertiesCollapsed(collapsed) {
      document.body.classList.toggle("properties-collapsed", collapsed);
      localStorage.setItem("h2-properties-collapsed", String(collapsed));
      propertiesToggleElement.textContent = collapsed ? "Properties" : "Hide";
      propertiesToggleElement.setAttribute("aria-expanded", collapsed ? "false" : "true");
      updateAllPanelsToggle();
    }

    function setAllPanelsCollapsed(collapsed) {
      setSidebarCollapsed(collapsed);
      setPropertiesCollapsed(collapsed);
      setFoldPanelCollapsed(timelinePanelElement, timelineToggleElement, "timeline", collapsed);
      setFoldPanelCollapsed(transcriptPanelElement, transcriptToggleElement, "transcript", collapsed);
      updateAllPanelsToggle();
    }

    function areAllPanelsCollapsed() {
      return document.body.classList.contains("sidebar-collapsed") &&
        document.body.classList.contains("properties-collapsed") &&
        document.body.classList.contains("timeline-collapsed") &&
        document.body.classList.contains("transcript-collapsed");
    }

    function updateAllPanelsToggle() {
      const collapsed = areAllPanelsCollapsed();
      allPanelsToggleElement.textContent = collapsed ? "Show All" : "Hide All";
      allPanelsToggleElement.setAttribute("aria-pressed", collapsed ? "true" : "false");
      allPanelsToggleElement.setAttribute("aria-label", collapsed ? "Show all panels" : "Hide all panels");
    }

    function setSidebarMode(mode) {
      sidebarMode = mode === "flows" ? "flows" : "sessions";
      localStorage.setItem("h2-sidebar-mode", sidebarMode);
      renderSidebarMode();
    }

    function setRoomMode(mode) {
      roomMode = mode === "flow" ? "flow" : "chat";
      localStorage.setItem("h2-room-mode", roomMode);
      flowViewToggleElement.textContent = roomMode === "flow" ? "Chat View" : "Flow View";
      flowViewToggleElement.setAttribute("aria-pressed", roomMode === "flow" ? "true" : "false");
      renderRoom(contextSessions(lastAgentSessions));
    }

    function renderSidebarMode() {
      const flowMode = sidebarMode === "flows";
      sessionListElement.hidden = flowMode;
      flowManagerElement.hidden = !flowMode;
      sessionsTabElement.classList.toggle("active", !flowMode);
      flowsTabElement.classList.toggle("active", flowMode);
      sessionsTabElement.setAttribute("aria-selected", flowMode ? "false" : "true");
      flowsTabElement.setAttribute("aria-selected", flowMode ? "true" : "false");
    }

    function setFoldPanelCollapsed(panel, toggle, name, collapsed) {
      panel.open = !collapsed;
      document.body.classList.toggle(name + "-collapsed", collapsed);
      localStorage.setItem("h2-" + name + "-collapsed", String(collapsed));
      toggle.textContent = collapsed ? "Show" : "Hide";
      toggle.setAttribute("aria-expanded", collapsed ? "false" : "true");
      updateAllPanelsToggle();
      window.requestAnimationFrame(clampChatHeightToCurrentBounds);
    }

    function preventSummaryToggle(panel) {
      const summary = panel.querySelector("summary");
      if (summary === null) {
        return;
      }
      summary.addEventListener("click", (event) => {
        event.preventDefault();
      });
      for (const control of summary.querySelectorAll("button,input,label")) {
        control.addEventListener("click", (event) => {
          event.stopPropagation();
        });
      }
    }

    function nextSelectedSessionId(currentId, sessions) {
      if (currentId !== null && sessions.some((session) => session.id === currentId)) {
        return currentId;
      }
      if (sessions.length === 0) {
        return null;
      }
      return [...sessions].sort((left, right) => activityTime(left) - activityTime(right)).at(-1).id;
    }

    function nextSelectedWorkflowId(currentId, workflows) {
      if (currentId !== null && workflows.some((workflow) => workflow.id === currentId)) {
        return currentId;
      }
      if (workflows.length === 0) {
        return null;
      }
      return [...workflows].sort((left, right) => workflowActivityTime(left) - workflowActivityTime(right)).at(-1).id;
    }

    function renderSessionList(sessions) {
      sessionCountElement.textContent = sessions.length + " agent sessions, " + lastHubSessions.length + " hub sessions";
      sessionListElement.innerHTML = "";
      if (sessions.length === 0) {
        sessionListElement.innerHTML = '<div class="empty">No agent sessions yet.</div>';
        return;
      }

      const sorted = [...sessions].sort((left, right) => activityTime(right) - activityTime(left));
      for (const session of sorted) {
        const item = document.createElement("button");
        item.type = "button";
        item.className = "session-card" + (session.id === selectedSessionId ? " selected" : "");
        item.addEventListener("click", () => {
          selectedSessionId = session.id;
          renderSessionList(lastAgentSessions);
          const context = contextSessions(lastAgentSessions);
          renderRoom(context);
          renderGantt(context);
          renderSelectedSession();
        });
        item.innerHTML =
          "<strong>" + escapeHtml(session.title || session.sessionId) + "</strong>" +
          '<div class="meta">' + escapeHtml(toolModelLabel(session)) + "</div>" +
          '<div class="meta">' + escapeHtml(projectLabel(session)) + "</div>" +
          '<span class="status ' + escapeHtml(session.status) + '">' + escapeHtml(session.status) + "</span>";
        sessionListElement.appendChild(item);
      }
    }

    function renderFlowList(workflows) {
      flowListElement.innerHTML = "";
      if (!Array.isArray(workflows) || workflows.length === 0) {
        flowListElement.innerHTML = '<div class="empty">No workflow runs yet.</div>';
        return;
      }

      const sorted = [...workflows].sort((left, right) => workflowActivityTime(right) - workflowActivityTime(left));
      for (const workflow of sorted) {
        const item = document.createElement("button");
        item.type = "button";
        item.className = "session-card" + (workflow.id === selectedWorkflowId ? " selected" : "");
        item.addEventListener("click", () => {
          selectedWorkflowId = workflow.id;
          setSidebarMode("flows");
          setRoomMode("flow");
          renderFlowList(lastWorkflowRuns);
          renderFlowManagerTrace(lastWorkflowRuns);
          renderRoom(contextSessions(lastAgentSessions));
        });
        item.innerHTML =
          "<strong>" + escapeHtml(workflow.cartridgeName || workflow.cartridgeId || "Workflow") + "</strong>" +
          '<div class="meta">' + escapeHtml(workflow.id || "-") + "</div>" +
          '<div class="meta">' + escapeHtml(workflow.cwd || "-") + "</div>" +
          '<span class="status ' + escapeHtml(workflow.status || "") + '">' + escapeHtml(workflow.status || "-") + "</span>";
        flowListElement.appendChild(item);
      }
    }

    function contextSessions(sessions) {
      if (sessions.length === 0) {
        return [];
      }
      const byId = new Map(sessions.map((session) => [session.id, session]));
      const selected = byId.get(selectedSessionId) || sessions[0];
      let root = selected;
      while (root.parentSessionId && byId.has(root.parentSessionId)) {
        root = byId.get(root.parentSessionId);
      }
      const children = new Map();
      for (const session of sessions) {
        if (!session.parentSessionId) {
          continue;
        }
        const list = children.get(session.parentSessionId) || [];
        list.push(session);
        children.set(session.parentSessionId, list);
      }
      const result = [];
      const visit = (session) => {
        result.push(session);
        for (const child of children.get(session.id) || []) {
          visit(child);
        }
      };
      visit(root);
      return result;
    }

    function renderRoom(sessions) {
      if (roomMode === "flow") {
        renderFlowMap(lastWorkflowRuns);
        return;
      }
      const workflow = sidebarMode === "flows" ? selectedWorkflow(lastWorkflowRuns) : null;
      if (workflow !== null && sidebarMode === "flows") {
        renderWorkflowChat(workflow, lastAgentSessions);
        return;
      }
      renderGroupChat(sessions);
    }

    function renderGroupChat(sessions) {
      const events = groupChatEvents(sessions);
      if (events.length === 0) {
        setElementHtml(groupChatElement, '<div class="empty">No chat activity yet.</div>');
        return;
      }
      setElementHtml(groupChatElement, events.map(renderChatEvent).join(""));
    }

    function groupChatEvents(sessions) {
      const byId = new Map(sessions.map((session) => [session.id, session]));
      const events = [];
      for (const session of sessions) {
        if (session.parentSessionId) {
          const parent = byId.get(session.parentSessionId);
          events.push({
            id: "join-" + session.id,
            kind: parent?.parentSessionId ? "system" : "user-system",
            timestamp: session.startedAt,
            author: "Humanize2",
            target: session.title || session.sessionId,
            text: (parent?.title || "Parent session") + " invited " + (session.title || session.sessionId) + " into the group."
          });
        }
        for (const entry of session.inputHistory || []) {
          const parent = session.parentSessionId ? byId.get(session.parentSessionId) : undefined;
          const origin = entry.origin || {};
          const fromWorkflow = origin.kind === "workflow";
          events.push({
            id: "input-" + session.id + "-" + entry.runId + "-" + entry.kind,
            kind: fromWorkflow ? "system" : (parent === undefined ? "user" : (entry.kind === "intervention" ? "intervention" : "message")),
            timestamp: entry.timestamp,
            author: fromWorkflow ? (origin.sender || "Flow Manager") : (parent === undefined ? "User" : (parent.title || parent.sessionId)),
            target: session.title || session.sessionId,
            text: entry.text
          });
        }
        events.push({
          id: "status-" + session.id + "-" + session.status,
          kind: session.parentSessionId ? "system" : "user-system",
          timestamp: session.finishedAt || session.startedAt,
          author: "Humanize2",
          target: session.title || session.sessionId,
          text: (session.title || session.sessionId) + " is " + session.status + "."
        });
      }
      return events.sort((left, right) => Date.parse(left.timestamp) - Date.parse(right.timestamp));
    }

    function renderFlowMap(workflows) {
      const workflow = selectedWorkflow(workflows);
      if (workflow === null) {
        setElementHtml(groupChatElement, '<div class="empty">No workflow run selected.</div>');
        return;
      }
      const head = '<div class="flow-map-head"><div><strong>' +
        escapeHtml(workflow.cartridgeName || workflow.cartridgeId || "Workflow") +
        '</strong><div class="meta">' + escapeHtml(workflow.id || "-") + "</div></div>" +
        '<span class="status ' + escapeHtml(workflow.status || "") + '">' + escapeHtml(workflow.status || "-") + "</span></div>";
      setElementHtml(groupChatElement,
        '<div class="flow-workspace">' +
          '<section class="flow-graph-view">' + head + renderWorkflowFlowProjection(workflow) + "</section>" +
        "</div>"
      );
    }

    function renderWorkflowFlowProjection(workflow) {
      const projection = workflow.projection?.flow;
      if (projection === undefined || !Array.isArray(projection.nodes) || projection.nodes.length === 0) {
        return '<div class="empty">No workflow projection available.</div>';
      }
      return '<div class="flow-map">' +
        '<div class="flow-sequence">' + projection.nodes.map((node) => renderFlowProjectionNode(node)).join("") + "</div>" +
      "</div>";
    }

    function renderFlowProjectionNode(node) {
      if (node.kind === "loop") {
        return '<section class="flow-loop flow-projection-node ' + escapeHtml(node.status || "pending") + '">' +
          '<div class="flow-loop-head">' +
            '<span>' + escapeHtml(node.label || node.id) + '</span>' +
            '<span>' + escapeHtml(loopSummary(node.loop)) + "</span>" +
          "</div>" +
          '<div class="flow-loop-body">' + (node.children || []).map((child) => renderFlowProjectionNode(child)).join("") + "</div>" +
        "</section>";
      }
      if (node.kind === "branch") {
        return '<section class="flow-branch flow-node flow-projection-node ' + escapeHtml(node.status || "pending") + '">' +
          '<div class="flow-node-title">' + escapeHtml(node.label || node.id) + "</div>" +
          '<div class="flow-node-meta">' + escapeHtml(node.branch?.on || "-") + "</div>" +
          '<div class="flow-branch-cases">' + renderBranchCases(node.branch?.cases || []) + "</div>" +
          renderFlowProjectionDetails(node) +
        "</section>";
      }
      return '<article class="flow-node flow-projection-node ' + escapeHtml(node.status || "pending") + '">' +
        '<div class="flow-node-title">' + escapeHtml(node.label || node.id) + "</div>" +
        renderFlowProjectionDetails(node) +
      "</article>";
    }

    function renderFlowProjectionDetails(node) {
      const meta = [];
      if (node.agent) {
        meta.push("agent " + (node.agent.role || "agent") + " / " + node.agent.tool);
      }
      if (node.script) {
        meta.push("script " + node.script.uses);
      }
      if (node.transform) {
        meta.push("transform " + node.transform.from + " -> " + node.transform.to);
      }
      if (node.await) {
        meta.push("await " + node.await.on);
      }
      if (node.human) {
        meta.push("human " + String(node.human.artifact || node.human.schema || "-"));
      }
      if (node.message) {
        meta.push("message " + node.message.target);
      }
      if (node.sleep) {
        meta.push("sleep " + String(node.sleep.durationMs) + "ms");
      }
      if (node.loop) {
        meta.push(loopSummary(node.loop));
      }
      return meta.map((line) => '<div class="flow-node-meta">' + escapeHtml(line) + "</div>").join("") +
        renderAgentInputs(node.agent?.inputs);
    }

    function renderAgentInputs(inputs) {
      if (!Array.isArray(inputs) || inputs.length === 0) {
        return "";
      }
      return '<div class="flow-node-inputs">' + inputs.map((input) => {
        const source = input.kind === "board"
          ? "board." + String(input.id || "-")
          : "artifact." + String(input.name || "-");
        const label = String(input.label || input.name || input.id || "-");
        const schema = input.schema ? " / " + String(input.schema) : "";
        const optional = input.optional ? " optional" : "";
        return '<div class="flow-node-input"><strong>input</strong><span>' +
          escapeHtml(label + " <- " + source + schema + optional) +
          "</span></div>";
      }).join("") + "</div>";
    }

    function renderBranchCases(cases) {
      if (!Array.isArray(cases) || cases.length === 0) {
        return '<div class="flow-branch-case"><span>-</span><span>no cases</span></div>';
      }
      return cases.map((branchCase) => {
        const target = branchCase.goto || branchCase.continueLoop || "-";
        const mode = branchCase.goto !== undefined ? "goto" : "continue";
        return '<div class="flow-branch-case">' +
          '<span>' + escapeHtml(branchCase.value || "-") + "</span>" +
          '<span>' + escapeHtml(mode + " " + target) + "</span>" +
        "</div>";
      }).join("");
    }

    function loopSummary(loop) {
      if (!loop) {
        return "-";
      }
      const iteration = loop.iteration === undefined ? 0 : loop.iteration;
      const max = loop.max === undefined ? "-" : loop.max;
      return loopCounterLabel(loop) + " " + String(iteration) + " / " + String(max);
    }

    function loopCounterLabel(loop) {
      const label = loop?.counterLabel || "iteration";
      return String(label);
    }

    function renderWorkflowChat(workflow, sessions) {
      const events = workflowChatEvents(workflow, sessions);
      if (events.length === 0) {
        setElementHtml(groupChatElement, '<div class="empty workflow-chat-empty">No workflow chat activity yet.</div>');
        return;
      }
      setElementHtml(groupChatElement, events.map(renderChatEvent).join(""));
    }

    function workflowChatEvents(workflow, sessions) {
      const relevantSessions = workflowSessions(workflow, sessions);
      if (relevantSessions.length === 0) {
        return [];
      }
      const byId = new Map(relevantSessions.map((session) => [session.id, session]));
      const events = [];

      for (const session of relevantSessions) {
        const nodeId = workflowNodeIdForSession(workflow, session);
        for (const entry of session.inputHistory || []) {
          const origin = entry.origin || {};
          const fromWorkflow = origin.kind === "workflow";
          events.push({
            id: "workflow-input-" + session.id + "-" + entry.runId + "-" + entry.kind,
            kind: fromWorkflow ? "system" : "user",
            timestamp: entry.timestamp,
            author: fromWorkflow ? (origin.sender || "Flow Manager") : (nodeId || session.title || session.sessionId),
            target: nodeId || session.title || session.sessionId,
            text: entry.text
          });
        }
        events.push({
          id: "workflow-status-" + session.id + "-" + session.status,
          kind: "user-system",
          timestamp: session.finishedAt || session.startedAt,
          author: nodeId || session.title || session.sessionId,
          target: session.title || session.sessionId,
          text: (session.title || session.sessionId) + " is " + session.status + "."
        });
      }

      for (const event of Array.isArray(workflow.events) ? workflow.events : []) {
        if (event.type !== "artifact.delivered") {
          continue;
        }
        const data = event.data || {};
        const name = data.name || "artifact";
        const producer = data.producer || "workflow";
        if ((workflow.nodeRunIds || {})[producer] === undefined && !byIdHasWorkflowSession(byId, producer, relevantSessions)) {
          continue;
        }
        const artifact = findWorkflowArtifactForEvent(workflow, event);
        events.push({
          id: "workflow-artifact-" + event.index + "-" + name,
          kind: "system",
          timestamp: event.timestamp,
          author: producer,
          target: workflowArtifactChatTarget(name),
          text: workflowArtifactMessage(name, data, artifact)
        });
      }

      return events.sort((left, right) => Date.parse(left.timestamp) - Date.parse(right.timestamp));
    }

    function findWorkflowArtifactForEvent(workflow, event) {
      const data = event.data || {};
      const artifacts = Array.isArray(workflow.artifacts) ? workflow.artifacts : [];
      const matches = artifacts.filter((artifact) =>
        artifact.name === data.name &&
        (data.producer === undefined || artifact.producer === data.producer)
      );
      if (matches.length === 0) {
        return undefined;
      }
      const sameTimestamp = matches.find((artifact) => artifact.createdAt === event.timestamp);
      return sameTimestamp || matches[matches.length - 1];
    }

    function workflowArtifactChatTarget(name) {
      if (name === "round-summary") {
        return "reviewer";
      }
      if (name === "review-verdict") {
        return "builder";
      }
      return name;
    }

    function workflowArtifactMessage(name, data, artifact) {
      const validation = data.validationStatus ? " (" + data.validationStatus + ")" : "";
      if (artifact === undefined) {
        return "Delivered " + name + validation;
      }
      return "Delivered " + name + validation + "\\n" + formatArtifactContentForChat(artifact.content);
    }

    function formatArtifactContentForChat(content) {
      if (content === undefined) {
        return "";
      }
      if (content === null) {
        return "null";
      }
      if (typeof content === "string") {
        return content;
      }
      if (typeof content !== "object") {
        return String(content);
      }
      const lines = [];
      appendObjectField(lines, content, "status");
      appendObjectField(lines, content, "summary");
      appendObjectField(lines, content, "reviewSummary");
      appendObjectField(lines, content, "reason");
      appendObjectField(lines, content, "planSummary");
      appendObjectField(lines, content, "remainingRisks");
      appendObjectField(lines, content, "requiredFollowUp");
      appendObjectField(lines, content, "findings");
      appendObjectField(lines, content, "completedWork");
      appendObjectField(lines, content, "verificationEvidence");
      appendObjectField(lines, content, "changedPaths");
      if (lines.length > 0) {
        return lines.join("\\n");
      }
      try {
        return JSON.stringify(content, null, 2);
      } catch {
        return String(content);
      }
    }

    function appendObjectField(lines, object, key) {
      if (!Object.prototype.hasOwnProperty.call(object, key)) {
        return;
      }
      const value = object[key];
      if (Array.isArray(value)) {
        lines.push(key + ": " + formatChatArray(value));
      } else if (value !== null && typeof value === "object") {
        lines.push(key + ": " + formatChatObject(value));
      } else {
        lines.push(key + ": " + String(value));
      }
    }

    function formatChatArray(value) {
      if (value.length === 0) {
        return "none";
      }
      return value.slice(0, 6).map((item) => {
        if (item === null || typeof item !== "object") {
          return String(item);
        }
        return formatChatObject(item);
      }).join("; ") + (value.length > 6 ? "; ..." : "");
    }

    function formatChatObject(value) {
      const parts = Object.entries(value)
        .slice(0, 6)
        .map(([key, item]) => key + "=" + (item === null || typeof item !== "object" ? String(item) : "object"));
      return parts.length === 0 ? "object" : parts.join(", ");
    }

    function workflowSessions(workflow, sessions) {
      const runIds = new Set(Object.values(workflow.nodeRunIds || {}));
      if (runIds.size === 0) {
        return [];
      }
      return sessions.filter((session) =>
        (session.attempts || []).some((attempt) => runIds.has(attempt.runId))
      );
    }

    function workflowNodeIdForSession(workflow, session) {
      const runIds = Object.entries(workflow.nodeRunIds || {});
      for (const [nodeId, runId] of runIds) {
        if ((session.attempts || []).some((attempt) => attempt.runId === runId)) {
          return nodeId;
        }
      }
      return undefined;
    }

    function byIdHasWorkflowSession(byId, producer, sessions) {
      if (byId.has(producer)) {
        return true;
      }
      return sessions.some((session) => session.agent === producer || session.title === producer || session.sessionId === producer);
    }

    function renderFlowManagerTrace(workflows) {
      const workflow = selectedWorkflow(workflows);
      if (workflow === null) {
        setElementHtml(flowManagerTraceElement, '<section class="workflow-panel"><div class="group-label">Execution Trace</div><div class="flow-trace-scroller"><div class="empty">No workflow run selected.</div></div></section>');
        return;
      }
      setElementHtml(flowManagerTraceElement, renderFlowTrace(workflow));
    }

    function selectedWorkflow(workflows) {
      if (!Array.isArray(workflows) || workflows.length === 0) {
        return null;
      }
      return workflows.find((workflow) => workflow.id === selectedWorkflowId) ||
        [...workflows].sort((left, right) => workflowActivityTime(right) - workflowActivityTime(left))[0];
    }

    function renderFlowTrace(workflow) {
      const events = Array.isArray(workflow.events) ? workflow.events : [];
      const body = events.length === 0
        ? '<div class="empty">No execution trace yet.</div>'
        : events.map(renderFlowTraceEvent).join("");
      return '<section class="workflow-panel"><div class="group-label">Execution Trace</div><div class="flow-trace-scroller">' + body + "</div></section>";
    }

    function renderFlowTraceEvent(event) {
      const kind = traceKind(event.type || "event");
      return '<article class="workflow-card flow-trace-card ' + escapeHtml(kind) + '">' +
        '<div class="property-lines">' +
          propertyLine("Time", formatTimestamp(event.timestamp)) +
          propertyLine("Type", traceTitle(event.type || "event")) +
          propertyLine("Category", kind) +
        "</div>" +
        renderTraceProperties(event.data) +
      "</article>";
    }

    function traceKind(type) {
      const first = String(type || "event").split(".")[0] || "event";
      return first.toLowerCase().replace(/[^a-z0-9_-]/g, "-");
    }

    function traceTitle(type) {
      const text = String(type || "event").replace(/[._-]+/g, " ");
      return text.replace(/\b\w/g, (char) => char.toUpperCase());
    }

    function renderTraceProperties(data) {
      if (data === undefined || data === null) {
        return '<div class="trace-empty">No details.</div>';
      }
      if (typeof data !== "object" || Array.isArray(data)) {
        return '<div class="property-lines">' +
          propertyLine("Details", formatTraceValue(data)) +
        "</div>";
      }
      const entries = Object.entries(data);
      if (entries.length === 0) {
        return '<div class="property-lines">' +
          propertyLine("Details", "No details.") +
        "</div>";
      }
      return '<div class="property-lines">' + entries.map(([key, value]) =>
        propertyLine(formatTraceKey(key), formatTraceValue(value))
      ).join("") + "</div>";
    }

    function formatTraceKey(key) {
      return String(key)
        .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
        .replace(/[._-]+/g, " ")
        .replace(/\b\w/g, (char) => char.toUpperCase());
    }

    function formatTraceValue(value) {
      if (value === undefined) {
        return "-";
      }
      if (value === null) {
        return "null";
      }
      if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
        return String(value);
      }
      if (Array.isArray(value)) {
        if (value.length === 0) {
          return "0 items";
        }
        const primitives = value.filter((item) =>
          item === null || ["string", "number", "boolean"].includes(typeof item)
        );
        if (primitives.length === value.length) {
          return value.length + " items: " + primitives.slice(0, 6).map(String).join(", ");
        }
        return value.length + " items";
      }
      const parts = Object.entries(value)
        .filter(([, item]) => item === null || ["string", "number", "boolean"].includes(typeof item))
        .slice(0, 6)
        .map(([key, item]) => formatTraceKey(key) + "=" + String(item));
      return parts.length === 0 ? "object" : parts.join(", ");
    }

    function flowVertexStates(workflow) {
      const byVertex = new Map();
      for (const event of workflow.events || []) {
        const data = event.data || {};
        const vertexId = data.vertexId || data.nodeId || data.target;
        if (!vertexId) {
          continue;
        }
        const state = byVertex.get(vertexId) || {
          id: vertexId,
          status: "pending",
          startedAt: undefined,
          finishedAt: undefined,
          events: []
        };
        state.events.push(event);
        if (event.type === "vertex.started") {
          state.status = "running";
          state.startedAt = event.timestamp;
        } else if (event.type === "vertex.completed") {
          state.status = "succeeded";
          state.finishedAt = event.timestamp;
        } else if (event.type === "vertex.failed") {
          state.status = "failed";
          state.finishedAt = event.timestamp;
        } else if (event.type === "agent.message_sent") {
          state.status = state.status === "pending" ? "message" : state.status;
        }
        byVertex.set(vertexId, state);
      }
      return [...byVertex.values()].sort((left, right) =>
        Date.parse(left.startedAt || left.finishedAt || "1970-01-01T00:00:00.000Z") -
        Date.parse(right.startedAt || right.finishedAt || "1970-01-01T00:00:00.000Z")
      );
    }

    function renderFlowNode(node) {
      const latest = Array.isArray(node.events) ? node.events[node.events.length - 1] : undefined;
      const className = "flow-node" + (node.primary ? " primary" : "") + (node.child ? " child" : "");
      return '<article class="' + className + '">' +
        '<div class="flow-node-title">' + escapeHtml(node.id) + "</div>" +
        '<div class="flow-node-meta">' + escapeHtml(node.status || "-") + "</div>" +
        '<div class="flow-node-meta">' + escapeHtml(node.meta || latest?.type || "-") + "</div>" +
        (latest === undefined ? "" : '<div class="flow-node-meta">' + escapeHtml(formatTimestamp(latest.timestamp)) + "</div>") +
      "</article>";
    }

    function renderChatEvent(event) {
      const expanded = expandedMessages.has(event.id);
      const message = collapseMessage(event.text, expanded);
      const target = event.target ? '<span class="chat-target">@' + escapeHtml(event.target) + "</span>" : "";
      const toggle = message.collapsible
        ? '<button class="message-toggle" type="button" data-message-toggle="' + escapeHtml(event.id) + '">' + (expanded ? "Show less" : "Show more") + "</button>"
        : "";
      return '<article class="chat-event ' + escapeHtml(event.kind) + '">' +
        '<div class="avatar">' + escapeHtml(initials(event.author)) + "</div>" +
        '<div class="chat-bubble">' +
          '<div class="chat-head"><span class="chat-author">' + escapeHtml(event.author) + "</span>" +
          target + '<span class="muted">' + escapeHtml(formatTimestamp(event.timestamp)) + "</span></div>" +
          '<div class="chat-text">' + escapeHtml(message.text) + "</div>" +
          toggle +
        "</div>" +
      "</article>";
    }

    function toggleLongMessage(messageId) {
      if (!messageId) {
        return;
      }
      if (expandedMessages.has(messageId)) {
        expandedMessages.delete(messageId);
      } else {
        expandedMessages.add(messageId);
      }
      renderRoom(contextSessions(lastAgentSessions));
    }

    function collapseMessage(text, expanded) {
      const value = String(text || "");
      const lines = value.split("\\n");
      const tooLong = value.length > 420 || lines.length > 8;
      if (!tooLong || expanded) {
        return { text: value, collapsible: tooLong };
      }
      const preview = lines.slice(0, 6).join("\\n");
      const suffix = value.length > preview.length ? "\\n... " + String(value.length - preview.length) + " more chars" : "";
      return { text: preview + suffix, collapsible: true };
    }

    function renderGantt(sessions) {
      if (sessions.length === 0) {
        setElementHtml(ganttElement, '<div class="empty">No timeline data yet.</div>');
        return;
      }
      const now = new Date().toISOString();
      const times = sessions.flatMap((session) => session.attempts.flatMap((attempt) => [
        Date.parse(attempt.startedAt),
        Date.parse(attempt.finishedAt || now)
      ]));
      const minTime = Math.min(...times);
      const maxTime = Math.max(...times);
      const span = Math.max(1, maxTime - minTime);
      const rows = sessions.map((session) =>
        '<div class="gantt-row">' +
          '<div class="gantt-label"><strong>' + escapeHtml(session.title || session.sessionId) + "</strong>" +
          escapeHtml(session.agent || "-") + " - " + escapeHtml(session.status || "-") + "</div>" +
          '<div class="track">' + renderSegments(session, minTime, span, now) + "</div>" +
          '<div class="gantt-stat">' + escapeHtml(formatDuration(session.durationMs) + " - " + formatTimeoutProgress(session)) + "</div>" +
        "</div>"
      ).join("");
      setElementHtml(ganttElement, '<div class="gantt">' + rows + "</div>");
    }

    function renderSegments(session, minTime, span, now) {
      return (session.attempts || []).map((attempt) => {
        const start = Date.parse(attempt.startedAt);
        const end = Date.parse(attempt.finishedAt || now);
        const left = ((start - minTime) / span) * 100;
        const width = Math.max(1, ((end - start) / span) * 100);
        const selected = session.id === selectedSessionId ? " selected" : "";
        return '<div class="segment ' + escapeHtml(attempt.status) + selected + '" title="' +
          escapeHtml(attempt.shortName + " - " + attempt.status) + '" style="left:' +
          left + "%;width:" + width + '%"></div>';
      }).join("");
    }

    function renderSelectedSession() {
      const session = lastAgentSessions.find((item) => item.id === selectedSessionId);
      if (session === undefined) {
        propertiesTitleElement.textContent = "Session Properties";
        setElementHtml(detailHeaderElement, '<div class="empty">No agent session selected.</div>' + renderWorkflowViews(lastWorkflowRuns));
        setPanelHtml(transcriptElement, '<div class="empty">No transcript selected.</div>');
        return;
      }

      const contextUsage = formatContextUsage(session.stats);
      const cachedInputTokens = (session.stats?.cacheReadInputTokens || 0) + (session.stats?.cacheCreationInputTokens || 0);
      const inputTokens = session.stats?.inputTokens || 0;
      const outputTokens = session.stats?.outputTokens || 0;
      const reasoningTokens = session.stats?.reasoningOutputTokens || 0;
      const totalTokens = Math.max(1, session.stats?.totalTokens || inputTokens + cachedInputTokens + outputTokens + reasoningTokens);
      propertiesTitleElement.innerHTML = "Session Properties: " + escapeHtml(session.title || session.sessionId);
      setElementHtml(detailHeaderElement, renderSessionDashboard(session, {
        contextUsage,
        cachedInputTokens,
        inputTokens,
        outputTokens,
        reasoningTokens,
        totalTokens,
        messages: messageCounts(session, lastAgentSessions)
      }) + renderWorkflowViews(lastWorkflowRuns));

      setPanelHtml(transcriptElement, renderTranscript(session));
    }

    function renderWorkflowViews(workflows) {
      if (!Array.isArray(workflows) || workflows.length === 0) {
        return '<section class="workflow-panel"><div class="group-label">Workflow-specific Views</div><div class="empty">No workflow records.</div></section>';
      }
      const recent = workflows.slice().sort((left, right) =>
        Date.parse(right.startedAt || right.createdAt || "1970-01-01T00:00:00.000Z") -
        Date.parse(left.startedAt || left.createdAt || "1970-01-01T00:00:00.000Z")
      ).slice(0, 3);
      return '<section class="workflow-panel"><div class="group-label">Workflow-specific Views</div>' +
        recent.map(renderWorkflowCard).join("") +
      "</section>";
    }

    function renderWorkflowCard(workflow) {
      const boards = Array.isArray(workflow.boards) ? workflow.boards : [];
      const views = Array.isArray(workflow.views) ? workflow.views : [];
      if (views.length === 0) {
        return "";
      }
      return '<div class="workflow-card">' +
        '<div class="summary-label">' + escapeHtml(workflow.cartridgeName || workflow.cartridgeId || "Workflow") + "</div>" +
        '<div class="property-lines">' +
          propertyLine("Status", workflow.status || "-") +
          propertyLine("Run", workflow.id || "-") +
          propertyLine("Boards", boards.length === 0 ? "-" : boards.map((board) => board.id).join(", ")) +
          propertyLine("Artifacts", String((workflow.artifacts || []).length)) +
        "</div>" +
        views.map((view) => renderWorkflowViewSlot(view, workflow)).join("") +
      "</div>";
    }

    function renderWorkflowViewSlot(view, workflow) {
      return '<div class="workflow-view-slot">' +
        '<div class="summary-label">View Slot: ' + escapeHtml(view.slot || "-") + "</div>" +
        renderBoundWorkflowView(view.html || "", workflow) +
      "</div>";
    }

    function renderBoundWorkflowView(html, workflow) {
      const documentObject = new DOMParser().parseFromString(String(html || ""), "text/html");
      const children = Array.from(documentObject.body.childNodes).map((node) => renderWorkflowViewNode(node, workflow)).join("");
      return '<div class="workflow-rendered-view">' + children + "</div>";
    }

    const allowedWorkflowViewTags = new Set([
      "section",
      "article",
      "div",
      "p",
      "span",
      "h1",
      "h2",
      "h3",
      "h4",
      "h5",
      "h6",
      "ul",
      "ol",
      "li",
      "dl",
      "dt",
      "dd",
      "table",
      "thead",
      "tbody",
      "tr",
      "th",
      "td",
      "code",
      "pre",
      "strong",
      "em",
      "time"
    ]);

    function renderWorkflowViewNode(node, workflow) {
      if (node.nodeType === Node.TEXT_NODE) {
        return escapeHtml(node.textContent || "");
      }
      if (node.nodeType !== Node.ELEMENT_NODE) {
        return "";
      }

      const tag = node.tagName.toLowerCase();
      if (tag === "script" || tag === "style" || tag === "iframe" || tag === "object" || tag === "embed") {
        return "";
      }
      if (!allowedWorkflowViewTags.has(tag)) {
        return Array.from(node.childNodes).map((child) => renderWorkflowViewNode(child, workflow)).join("");
      }

      // The hub pre-resolves data-h2-bind server-side using the shared expression grammar,
      // so the client renders the (already substituted) inner content directly. This keeps
      // view paths and predicate paths from drifting.
      const innerHtml = Array.from(node.childNodes).map((child) => renderWorkflowViewNode(child, workflow)).join("");
      return "<" + tag + ">" + innerHtml + "</" + tag + ">";
    }

    function renderSessionDashboard(session, stats) {
      const model = session.modelLabel || session.model || "unknown";
      return '<div class="session-dashboard">' +
        '<div class="session-summary">' +
          '<div><div class="summary-label">Tool/Model</div><div class="summary-value">' +
          escapeHtml(toolModelLabel(session)) + "</div></div>" +
          '<span class="status ' + escapeHtml(session.status || "") + '">' + escapeHtml(session.status || "-") + "</span>" +
        "</div>" +
        '<div class="property-groups">' +
          '<section class="property-group identity">' +
            '<div class="group-label">Identity</div>' +
            '<div class="property-lines">' +
              propertyLine("Tool", session.agent || "-") +
              propertyLine("Model", model) +
              propertyLine("Working Path", projectLabel(session)) +
              propertyLine("Session ID", session.sessionId || session.id) +
            "</div>" +
          "</section>" +
          '<section class="property-group">' +
            '<div class="group-label">Runtime</div>' +
            '<div class="property-lines">' +
              propertyLine("Status", session.status || "-") +
              propertyLine("Duration", formatDuration(session.durationMs || 0)) +
              propertyLine("Messages", messageCountLabel(stats.messages)) +
              propertyLine("Latest Context", stats.contextUsage || "-") +
            "</div>" +
          "</section>" +
        "</div>" +
        '<div class="metric-strip">' +
          metricTile("Input Tokens", formatNumber(stats.inputTokens)) +
          metricTile("Output Tokens", formatNumber(stats.outputTokens)) +
          metricTile("Total Tokens", formatNumber(stats.totalTokens)) +
        "</div>" +
        '<section class="property-group token-group">' +
          '<div class="group-label">Token Flow</div>' +
          '<div class="token-board">' +
            tokenRow("Input", stats.inputTokens, stats.totalTokens, "") +
            (stats.cachedInputTokens <= 0 ? "" : tokenRow("Cached Input", stats.cachedInputTokens, stats.totalTokens, "cached")) +
            tokenRow("Output", stats.outputTokens, stats.totalTokens, "output") +
            (stats.reasoningTokens <= 0 ? "" : tokenRow("Reasoning", stats.reasoningTokens, stats.totalTokens, "reasoning")) +
          "</div>" +
        "</section>" +
      "</div>";
    }

    function messageCountLabel(counts) {
      return "received " + String(counts.received) + " / sent " + String(counts.sent);
    }

    function messageCounts(session, sessions) {
      const received = (session.inputHistory || []).length;
      const sent = sessions
        .filter((candidate) => candidate.parentSessionId === session.id)
        .reduce((total, candidate) => total + (candidate.inputHistory || []).length, 0);
      return { received, sent };
    }

    function renderTranscript(session) {
      const entries = [];
      for (const entry of session.inputHistory || []) {
        entries.push({
          timestamp: entry.timestamp,
          html: transcriptEntry("input", entry.kind === "intervention" ? "Message" : "Prompt", entry.text, entry.timestamp)
        });
      }
      for (const event of session.outputEvents || []) {
        const lines = splitLines(event.text || "");
        for (const line of lines) {
          const rendered = event.stream === "stdout" ? renderJsonLine(line) : null;
          if (rendered !== null) {
            pushTranscript(entries, "log", "Tool", rendered.log, event.timestamp);
            pushTranscript(entries, "output", "Output", rendered.output, event.timestamp);
          } else if (event.stream === "stderr") {
            pushTranscript(entries, "error", "Log", line, event.timestamp);
          } else {
            pushTranscript(entries, "output", "Output", line, event.timestamp);
          }
        }
      }
      if (entries.length === 0 && typeof session.resultStdout === "string") {
        pushTranscript(entries, "output", "Output", session.resultStdout);
      }
      const body = entries.length === 0
        ? '<div class="empty">No transcript yet.</div>'
        : entries.sort((left, right) => Date.parse(left.timestamp || "") - Date.parse(right.timestamp || "")).map((entry) => entry.html).join("");
      return '<div class="' + escapeHtml(transcriptClass(session.agent)) + '">' + body + "</div>";
    }

    function transcriptClass(agent) {
      if (agent === "codex") {
        return "transcript codex";
      }
      if (agent === "claude") {
        return "transcript claude";
      }
      return "transcript generic";
    }

    function pushTranscript(entries, kind, label, value, timestamp) {
      if (value !== undefined && value !== null && String(value).length > 0) {
        entries.push({
          timestamp,
          html: transcriptEntry(kind, label, String(value), timestamp)
        });
      }
    }

    function transcriptEntry(kind, label, text, timestamp) {
      return '<div class="transcript-entry ' + escapeHtml(kind) + '">' +
        '<div class="transcript-kicker">' + escapeHtml(label) + " - " + escapeHtml(formatTimestamp(timestamp)) + "</div>" +
        escapeHtml(text) +
      "</div>";
    }

    function renderJsonLine(line) {
      const value = parseJsonLine(line);
      if (value === null) {
        return null;
      }
      if (value.type === "thread.started") {
        return { log: "Thread started: " + (value.thread_id || value.session_id || "-") };
      }
      if (value.type === "turn.started") {
        return { log: "Turn started" };
      }
      if (value.type === "turn.completed") {
        return { log: renderUsage(value.usage) };
      }
      if (value.type === "result" && typeof value.result === "string") {
        return { output: value.result };
      }
      if (value.type === "text" && typeof value.text === "string") {
        return { output: value.text };
      }
      if (value.type === "assistant" && typeof value.message === "string") {
        return { output: value.message };
      }
      if (value.item && value.item.type === "agent_message" && typeof value.item.text === "string") {
        return { output: value.item.text };
      }
      if (value.item && value.item.type === "command_execution") {
        return { log: renderCommandItem(value.item) };
      }
      if (value.item && value.item.type === "file_change") {
        return { log: renderFileChangeItem(value.item) };
      }

      return { log: JSON.stringify(value, null, 2) };
    }

    function parseJsonLine(line) {
      const trimmed = line.trim();
      if (trimmed.length === 0 || !trimmed.startsWith("{")) {
        return null;
      }

      try {
        return JSON.parse(trimmed);
      } catch {
        return null;
      }
    }

    function renderCommandItem(item) {
      const parts = [];
      if (item.command) {
        parts.push("$ " + item.command);
      }
      if (item.aggregated_output) {
        parts.push(String(item.aggregated_output).trimEnd());
      }
      if (item.status || item.exit_code !== undefined) {
        parts.push("[status: " + (item.status || "-") + ", exit: " + String(item.exit_code) + "]");
      }
      return parts.join("\\n");
    }

    function renderFileChangeItem(item) {
      const changes = Array.isArray(item.changes) ? item.changes : [];
      if (changes.length === 0) {
        return "[file change]";
      }
      return changes.map((change) => "[file " + (change.kind || "change") + "] " + change.path).join("\\n");
    }

    function renderUsage(usage) {
      if (!usage || typeof usage !== "object") {
        return "Turn completed";
      }
      const input = usage.input_tokens === undefined ? "-" : String(usage.input_tokens);
      const output = usage.output_tokens === undefined ? "-" : String(usage.output_tokens);
      const cached = usage.cached_input_tokens ?? usage.cache_read_input_tokens ?? usage.cacheReadInputTokens;
      const cacheCreation = usage.cache_creation_input_tokens ?? usage.cacheCreationInputTokens;
      const reasoning = usage.reasoning_output_tokens ?? usage.reasoningOutputTokens;
      const parts = ["Turn completed", "input tokens " + input, "output tokens " + output];
      if (cached !== undefined) {
        parts.push("cached input " + String(cached));
      }
      if (cacheCreation !== undefined) {
        parts.push("cache creation " + String(cacheCreation));
      }
      if (reasoning !== undefined) {
        parts.push("reasoning output " + String(reasoning));
      }
      return parts.join(" - ");
    }

    function propertyLine(name, value) {
      return '<div class="property-line"><div class="property-label">' + escapeHtml(name) +
        '</div><div class="property-value">' + escapeHtml(value) + "</div></div>";
    }

    function metricTile(name, value) {
      return '<div class="metric-tile"><div class="metric-label">' + escapeHtml(name) +
        '</div><div class="metric-value">' + escapeHtml(value) + "</div></div>";
    }

    function tokenRow(name, value, total, className) {
      const percent = total <= 0 ? 0 : Math.min(100, Math.max(0, (value / total) * 100));
      const empty = value <= 0 ? " empty" : "";
      return '<div class="token-row"><div class="property-label">' + escapeHtml(name) +
        '</div><div class="token-track"><div class="token-fill ' + escapeHtml(className) + empty +
        '" style="width:' + percent.toFixed(2) + '%"></div></div><div class="property-value">' +
        escapeHtml(formatNumber(value)) + "</div></div>";
    }

    function formatTimeoutProgress(session) {
      const timeoutMs = session.timeoutMs || 0;
      if (timeoutMs <= 0) {
        return "-";
      }
      const percent = Math.min(100, Math.max(0, ((session.durationMs || 0) / timeoutMs) * 100));
      const digits = percent < 10 ? 1 : 0;
      return percent.toFixed(digits) + "% of timeout";
    }

    function formatContextUsage(stats) {
      if (!stats) {
        return undefined;
      }
      const used = stats.contextUsedTokens;
      if (!Number.isFinite(used) || !stats.contextWindowTokens) {
        return undefined;
      }
      const percent = stats.contextUsagePercent === undefined
        ? (used / stats.contextWindowTokens) * 100
        : stats.contextUsagePercent;
      return formatNumber(used) + " / " + formatNumber(stats.contextWindowTokens) + " (" + formatPercent(percent) + ")";
    }

    function formatPercent(value) {
      if (!Number.isFinite(value)) {
        return "-";
      }
      const digits = value < 10 ? 1 : 0;
      return value.toFixed(digits) + "%";
    }

    function formatNumber(value) {
      if (!Number.isFinite(value)) {
        return "-";
      }
      return new Intl.NumberFormat().format(value);
    }

    function formatDuration(ms) {
      if (!Number.isFinite(ms) || ms < 0) {
        return "-";
      }
      const seconds = Math.floor(ms / 1000);
      if (seconds < 60) {
        return seconds + "s";
      }
      const minutes = Math.floor(seconds / 60);
      const remainingSeconds = seconds % 60;
      if (minutes < 60) {
        return minutes + "m " + remainingSeconds + "s";
      }
      const hours = Math.floor(minutes / 60);
      const remainingMinutes = minutes % 60;
      return hours + "h " + remainingMinutes + "m";
    }

    function formatTimestamp(value) {
      if (!value) {
        return "-";
      }
      const date = new Date(value);
      if (Number.isNaN(date.getTime())) {
        return value;
      }
      return date.toLocaleTimeString();
    }

    function activityTime(session) {
      return Date.parse(session.finishedAt || session.startedAt || "1970-01-01T00:00:00.000Z");
    }

    function workflowActivityTime(workflow) {
      return Date.parse(workflow.finishedAt || workflow.startedAt || workflow.createdAt || "1970-01-01T00:00:00.000Z");
    }

    function projectLabel(session) {
      if (session.project && session.project.path) {
        return session.project.path;
      }
      return session.cwd || "-";
    }

    function toolModelLabel(session) {
      const agent = session.agent || "-";
      const model = session.model || modelNameFromLabel(session.modelLabel) || "unknown";
      if (session.reasoningEffort) {
        return agent + ": " + model + " [" + session.reasoningEffort + "]";
      }
      return agent + ": " + model;
    }

    function modelNameFromLabel(label) {
      if (!label) {
        return undefined;
      }
      const text = String(label);
      const efforts = ["xhigh", "high", "medium", "low", "minimal"];
      for (const effort of efforts) {
        const suffix = " " + effort;
        if (text.endsWith(suffix)) {
          return text.slice(0, -suffix.length);
        }
      }
      return text;
    }

    function shortSessionId(value) {
      if (!value) {
        return "-";
      }
      const text = String(value);
      return text.length <= 18 ? text : text.slice(0, 8) + "..." + text.slice(-6);
    }

    function initials(value) {
      const words = String(value || "?").replace(/[^a-zA-Z0-9 ]/g, " ").trim().split(/\\s+/).filter(Boolean);
      if (words.length === 0) {
        return "?";
      }
      return words.slice(0, 2).map((word) => word[0]).join("");
    }

    function splitLines(text) {
      if (text.length === 0) {
        return [];
      }
      const lines = text.split(/\\r?\\n/);
      return lines[lines.length - 1] === "" ? lines.slice(0, -1) : lines;
    }

    function setPanelHtml(element, html) {
      if (hasActiveSelectionInside(element)) {
        return;
      }
      const follow = followOutputElement.checked;
      const scrollTop = element.scrollTop;
      if (element.innerHTML !== html) {
        element.innerHTML = html;
      }
      if (follow) {
        element.scrollTop = element.scrollHeight;
      } else {
        element.scrollTop = scrollTop;
      }
    }

    function setElementHtml(element, html) {
      if (hasActiveSelectionInside(element)) {
        return;
      }
      if (element.innerHTML !== html) {
        element.innerHTML = html;
      }
    }

    function hasActiveSelectionInside(element) {
      const selection = window.getSelection();
      if (selection === null || selection.rangeCount === 0 || selection.isCollapsed) {
        return false;
      }
      for (let index = 0; index < selection.rangeCount; index++) {
        const range = selection.getRangeAt(index);
        if (element.contains(range.commonAncestorContainer)) {
          return true;
        }
        if (typeof range.intersectsNode === "function") {
          try {
            if (range.intersectsNode(element)) {
              return true;
            }
          } catch {
            continue;
          }
        }
      }
      return false;
    }

    function escapeHtml(value) {
      return String(value).replace(/[&<>"']/g, (char) => ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;"
      }[char]));
    }

    refresh();
    setInterval(refresh, 1000);
  </script>
</body>
</html>`;
}
