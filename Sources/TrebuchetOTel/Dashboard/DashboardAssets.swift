public enum DashboardAssets {
    public static let indexHTML: String = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>TrebuchetOTel</title>
        <style>
            :root {
                --bg: #1a1a2e;
                --surface: #16213e;
                --surface-hover: #1a2744;
                --text: #e0e0e0;
                --text-muted: #8892a0;
                --accent: #0f3460;
                --success: #4ecca3;
                --error: #e74c3c;
                --warning: #f39c12;
                --client: #3498db;
                --border: #2a2a4a;
            }

            * {
                margin: 0;
                padding: 0;
                box-sizing: border-box;
            }

            body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                background: var(--bg);
                color: var(--text);
                line-height: 1.5;
                min-height: 100vh;
            }

            /* Header */
            .header {
                background: var(--surface);
                border-bottom: 1px solid var(--border);
                padding: 16px 24px;
                position: sticky;
                top: 0;
                z-index: 100;
            }

            .header-top {
                display: flex;
                align-items: center;
                justify-content: space-between;
                margin-bottom: 12px;
            }

            .header-title {
                font-size: 20px;
                font-weight: 700;
                letter-spacing: -0.3px;
                display: flex;
                align-items: center;
                gap: 8px;
            }

            .header-title .icon {
                font-size: 22px;
            }

            .stats-row {
                display: flex;
                gap: 24px;
                margin-bottom: 12px;
            }

            .stat-card {
                background: var(--accent);
                border-radius: 8px;
                padding: 10px 16px;
                min-width: 140px;
            }

            .stat-label {
                font-size: 11px;
                text-transform: uppercase;
                letter-spacing: 0.5px;
                color: var(--text-muted);
                margin-bottom: 2px;
            }

            .stat-value {
                font-size: 22px;
                font-weight: 700;
            }

            .stat-value.error-rate {
                color: var(--success);
            }

            .stat-value.error-rate.high {
                color: var(--error);
            }

            .controls {
                display: flex;
                gap: 10px;
                align-items: center;
                flex-wrap: wrap;
            }

            .controls select,
            .controls input[type="text"] {
                background: var(--accent);
                color: var(--text);
                border: 1px solid var(--border);
                border-radius: 6px;
                padding: 8px 12px;
                font-size: 13px;
                outline: none;
                transition: border-color 0.15s;
            }

            .controls select:focus,
            .controls input[type="text"]:focus {
                border-color: var(--client);
            }

            .controls select {
                cursor: pointer;
                min-width: 140px;
            }

            .controls input[type="text"] {
                min-width: 200px;
            }

            .auto-refresh-toggle {
                display: flex;
                align-items: center;
                gap: 6px;
                font-size: 13px;
                color: var(--text-muted);
                cursor: pointer;
                user-select: none;
                margin-left: auto;
            }

            .toggle-switch {
                position: relative;
                width: 36px;
                height: 20px;
                background: var(--accent);
                border-radius: 10px;
                transition: background 0.2s;
                cursor: pointer;
            }

            .toggle-switch.active {
                background: var(--success);
            }

            .toggle-switch::after {
                content: "";
                position: absolute;
                top: 2px;
                left: 2px;
                width: 16px;
                height: 16px;
                background: var(--text);
                border-radius: 50%;
                transition: transform 0.2s;
            }

            .toggle-switch.active::after {
                transform: translateX(16px);
            }

            /* Trace table */
            .trace-table-container {
                padding: 0 24px 24px;
            }

            .trace-table {
                width: 100%;
                border-collapse: collapse;
                margin-top: 16px;
            }

            .trace-table th {
                text-align: left;
                padding: 10px 12px;
                font-size: 11px;
                text-transform: uppercase;
                letter-spacing: 0.5px;
                color: var(--text-muted);
                border-bottom: 1px solid var(--border);
                position: sticky;
                top: 0;
                background: var(--bg);
                white-space: nowrap;
            }

            .trace-table td {
                padding: 10px 12px;
                font-size: 13px;
                border-bottom: 1px solid var(--border);
                white-space: nowrap;
            }

            .trace-row {
                cursor: pointer;
                transition: background 0.1s;
            }

            .trace-row:hover {
                background: var(--surface-hover);
            }

            .trace-row.error-row {
                background: rgba(231, 76, 60, 0.08);
            }

            .trace-row.error-row:hover {
                background: rgba(231, 76, 60, 0.14);
            }

            .trace-row.expanded {
                background: var(--surface);
            }

            .status-dot {
                display: inline-block;
                width: 8px;
                height: 8px;
                border-radius: 50%;
                background: var(--success);
            }

            .status-dot.error {
                background: var(--error);
            }

            .duration-cell {
                font-variant-numeric: tabular-nums;
                font-family: "SF Mono", "Fira Code", "Cascadia Code", monospace;
                font-size: 12px;
            }

            .time-cell {
                color: var(--text-muted);
            }

            .spans-count {
                color: var(--text-muted);
                font-size: 12px;
            }

            /* Trace detail / waterfall */
            .trace-detail {
                display: none;
            }

            .trace-detail.open {
                display: table-row;
            }

            .trace-detail-inner {
                padding: 16px 12px;
                background: var(--surface);
                border-bottom: 2px solid var(--border);
            }

            .waterfall {
                width: 100%;
            }

            .waterfall-header {
                display: flex;
                align-items: center;
                padding: 6px 0;
                border-bottom: 1px solid var(--border);
                margin-bottom: 4px;
            }

            .waterfall-header-label {
                font-size: 11px;
                text-transform: uppercase;
                letter-spacing: 0.5px;
                color: var(--text-muted);
            }

            .waterfall-header-label.name-col {
                width: 38%;
                flex-shrink: 0;
                padding-left: 8px;
            }

            .waterfall-header-label.bar-col {
                flex: 1;
                text-align: right;
                padding-right: 8px;
            }

            .waterfall-row {
                display: flex;
                align-items: center;
                padding: 3px 0;
                border-radius: 3px;
                transition: background 0.1s;
                position: relative;
            }

            .waterfall-row:hover {
                background: var(--surface-hover);
            }

            .waterfall-label {
                width: 38%;
                flex-shrink: 0;
                display: flex;
                align-items: center;
                gap: 6px;
                padding-right: 12px;
                overflow: hidden;
            }

            .waterfall-label-text {
                font-size: 12px;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
            }

            .span-kind-badge {
                font-size: 9px;
                font-weight: 600;
                text-transform: uppercase;
                letter-spacing: 0.3px;
                padding: 1px 5px;
                border-radius: 3px;
                background: var(--accent);
                color: var(--text-muted);
                flex-shrink: 0;
            }

            .waterfall-bar-area {
                flex: 1;
                height: 22px;
                position: relative;
            }

            .waterfall-bar {
                position: absolute;
                top: 3px;
                height: 16px;
                border-radius: 3px;
                min-width: 2px;
                opacity: 0.85;
                transition: opacity 0.1s;
            }

            .waterfall-bar:hover {
                opacity: 1;
            }

            .waterfall-bar.ok {
                background: var(--success);
            }

            .waterfall-bar.error {
                background: var(--error);
            }

            .waterfall-bar.client {
                background: var(--client);
            }

            .waterfall-bar-duration {
                position: absolute;
                top: 4px;
                font-size: 10px;
                color: var(--text-muted);
                white-space: nowrap;
                font-variant-numeric: tabular-nums;
            }

            .waterfall-time-markers {
                display: flex;
                justify-content: space-between;
                padding-top: 4px;
                border-top: 1px solid var(--border);
                margin-top: 4px;
            }

            .waterfall-time-marker {
                font-size: 10px;
                color: var(--text-muted);
                font-variant-numeric: tabular-nums;
            }

            /* Tooltip */
            .tooltip {
                position: fixed;
                background: #0d1117;
                border: 1px solid var(--border);
                border-radius: 8px;
                padding: 10px 14px;
                font-size: 12px;
                z-index: 1000;
                pointer-events: none;
                max-width: 360px;
                box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
                display: none;
            }

            .tooltip.visible {
                display: block;
            }

            .tooltip-title {
                font-weight: 600;
                margin-bottom: 6px;
                font-size: 13px;
            }

            .tooltip-row {
                display: flex;
                justify-content: space-between;
                gap: 16px;
                padding: 2px 0;
            }

            .tooltip-key {
                color: var(--text-muted);
            }

            .tooltip-value {
                font-family: "SF Mono", "Fira Code", monospace;
                font-size: 11px;
                text-align: right;
                word-break: break-all;
            }

            .tooltip-attrs {
                margin-top: 6px;
                padding-top: 6px;
                border-top: 1px solid var(--border);
            }

            /* Empty / loading states */
            .empty-state {
                text-align: center;
                padding: 60px 24px;
                color: var(--text-muted);
            }

            .empty-state-icon {
                font-size: 40px;
                margin-bottom: 12px;
                opacity: 0.5;
            }

            .empty-state-text {
                font-size: 15px;
            }

            .loading-indicator {
                display: inline-block;
                width: 12px;
                height: 12px;
                border: 2px solid var(--border);
                border-top-color: var(--client);
                border-radius: 50%;
                animation: spin 0.8s linear infinite;
                margin-left: 8px;
                vertical-align: middle;
            }

            @keyframes spin {
                to { transform: rotate(360deg); }
            }

            /* Tab bar */
            .tab-bar {
                display: flex;
                gap: 0;
                margin-bottom: 12px;
                border-bottom: 1px solid var(--border);
            }

            .tab-btn {
                background: none;
                border: none;
                color: var(--text-muted);
                font-size: 13px;
                font-weight: 600;
                padding: 8px 20px;
                cursor: pointer;
                border-bottom: 2px solid transparent;
                transition: color 0.15s, border-color 0.15s;
            }

            .tab-btn:hover {
                color: var(--text);
            }

            .tab-btn.active {
                color: var(--text);
                border-bottom-color: var(--client);
            }

            /* Logs view */
            .logs-container {
                padding: 0 24px 24px;
                display: none;
            }

            .logs-container.active {
                display: block;
            }

            .trace-table-container.active {
                display: block;
            }

            .log-controls {
                display: flex;
                gap: 10px;
                align-items: center;
                flex-wrap: wrap;
                margin-bottom: 12px;
            }

            .log-controls select,
            .log-controls input[type="text"] {
                background: var(--accent);
                color: var(--text);
                border: 1px solid var(--border);
                border-radius: 6px;
                padding: 8px 12px;
                font-size: 13px;
                outline: none;
                transition: border-color 0.15s;
            }

            .log-controls select:focus,
            .log-controls input[type="text"]:focus {
                border-color: var(--client);
            }

            .log-controls select {
                cursor: pointer;
                min-width: 140px;
            }

            .log-controls input[type="text"] {
                min-width: 200px;
            }

            .log-list {
                display: flex;
                flex-direction: column;
                gap: 1px;
            }

            .log-entry {
                display: flex;
                align-items: flex-start;
                gap: 10px;
                padding: 8px 12px;
                background: var(--surface);
                border-radius: 4px;
                cursor: default;
                transition: background 0.1s;
                font-size: 13px;
            }

            .log-entry:hover {
                background: var(--surface-hover);
            }

            .log-entry.has-trace {
                cursor: pointer;
            }

            .log-timestamp {
                color: var(--text-muted);
                font-size: 12px;
                white-space: nowrap;
                min-width: 64px;
                flex-shrink: 0;
            }

            .log-severity {
                font-size: 10px;
                font-weight: 700;
                text-transform: uppercase;
                letter-spacing: 0.3px;
                padding: 2px 7px;
                border-radius: 3px;
                white-space: nowrap;
                flex-shrink: 0;
                min-width: 52px;
                text-align: center;
            }

            .log-severity.trace-sev { background: rgba(142,142,142,0.2); color: #8e8e8e; }
            .log-severity.debug { background: rgba(142,142,142,0.2); color: #aaa; }
            .log-severity.info { background: rgba(78,204,163,0.15); color: var(--success); }
            .log-severity.warn { background: rgba(243,156,18,0.15); color: var(--warning); }
            .log-severity.error { background: rgba(231,76,60,0.15); color: var(--error); }
            .log-severity.fatal { background: rgba(231,76,60,0.3); color: #ff6b6b; }

            .log-service {
                color: var(--client);
                font-size: 12px;
                white-space: nowrap;
                flex-shrink: 0;
                min-width: 80px;
            }

            .log-body {
                flex: 1;
                word-break: break-word;
                font-family: "SF Mono", "Fira Code", "Cascadia Code", monospace;
                font-size: 12px;
                line-height: 1.4;
            }

            .log-trace-link {
                font-size: 10px;
                color: var(--client);
                opacity: 0.7;
                flex-shrink: 0;
            }

            .logs-empty {
                text-align: center;
                padding: 60px 24px;
                color: var(--text-muted);
            }

            .logs-load-more {
                display: block;
                margin: 16px auto;
                background: var(--accent);
                color: var(--text-muted);
                border: 1px solid var(--border);
                border-radius: 6px;
                padding: 8px 24px;
                font-size: 13px;
                cursor: pointer;
                transition: border-color 0.15s;
            }

            .logs-load-more:hover {
                border-color: var(--client);
                color: var(--text);
            }

            /* Responsive */
            @media (max-width: 768px) {
                .stats-row {
                    gap: 10px;
                }

                .stat-card {
                    min-width: 100px;
                    padding: 8px 10px;
                }

                .stat-value {
                    font-size: 18px;
                }

                .controls input[type="text"] {
                    min-width: 140px;
                }

                .waterfall-label {
                    width: 30%;
                }

                .waterfall-header-label.name-col {
                    width: 30%;
                }
            }
        </style>
    </head>
    <body>
        <div class="header">
            <div class="header-top">
                <div class="header-title">
                    <span class="icon">&#x1F3F0;</span>
                    TrebuchetOTel
                </div>
                <form method="POST" action="/logout" style="margin:0">
                    <button type="submit" style="background:var(--accent);color:var(--text-muted);border:1px solid var(--border);border-radius:6px;padding:6px 14px;font-size:12px;cursor:pointer;">Sign out</button>
                </form>
            </div>
            <div class="stats-row" id="stats-row">
                <div class="stat-card">
                    <div class="stat-label">Total Traces</div>
                    <div class="stat-value" id="stat-traces">--</div>
                </div>
                <div class="stat-card">
                    <div class="stat-label">Error Rate</div>
                    <div class="stat-value error-rate" id="stat-error-rate">--</div>
                </div>
                <div class="stat-card">
                    <div class="stat-label">P95 Latency</div>
                    <div class="stat-value" id="stat-p95">--</div>
                </div>
            </div>
            <div class="controls">
                <select id="service-filter">
                    <option value="">All Services</option>
                </select>
                <select id="status-filter">
                    <option value="">All</option>
                    <option value="error">Errors Only</option>
                </select>
                <input type="text" id="search-input" placeholder="Search operations..." />
                <label class="auto-refresh-toggle">
                    <div class="toggle-switch" id="refresh-toggle"></div>
                    Auto-refresh
                </label>
            </div>
            <div class="tab-bar">
                <button class="tab-btn active" id="tab-traces" data-tab="traces">Traces</button>
                <button class="tab-btn" id="tab-logs" data-tab="logs">Logs</button>
            </div>
        </div>

        <div class="trace-table-container active" id="traces-view">
            <table class="trace-table" id="trace-table">
                <thead>
                    <tr>
                        <th>Time</th>
                        <th>Service</th>
                        <th>Operation</th>
                        <th>Duration</th>
                        <th>Status</th>
                        <th>Spans</th>
                    </tr>
                </thead>
                <tbody id="trace-tbody"></tbody>
            </table>
            <div class="empty-state" id="empty-state">
                <div class="empty-state-icon">&#x1F3F0;</div>
                <div class="empty-state-text">No traces yet. Waiting for data...</div>
            </div>
        </div>

        <div class="logs-container" id="logs-view">
            <div class="log-controls">
                <select id="log-service-filter">
                    <option value="">All Services</option>
                </select>
                <select id="log-severity-filter">
                    <option value="">All Levels</option>
                    <option value="5">DEBUG+</option>
                    <option value="9">INFO+</option>
                    <option value="13">WARN+</option>
                    <option value="17">ERROR+</option>
                    <option value="21">FATAL</option>
                </select>
                <input type="text" id="log-search-input" placeholder="Search log messages..." />
            </div>
            <div class="log-list" id="log-list"></div>
            <div class="logs-empty" id="logs-empty" style="display:none;">
                <div class="empty-state-icon">&#x1F4DC;</div>
                <div class="empty-state-text">No logs yet. Waiting for data...</div>
            </div>
        </div>

        <div class="tooltip" id="tooltip"></div>

        <script>
            (function() {
                "use strict";

                // State
                let traces = [];
                let expandedTraceId = null;
                let autoRefresh = false;
                let refreshInterval = null;
                let services = [];
                let activeTab = "traces";
                let logs = [];
                let logNextCursor = null;

                // DOM refs
                const traceTableBody = document.getElementById("trace-tbody");
                const emptyState = document.getElementById("empty-state");
                const serviceFilter = document.getElementById("service-filter");
                const statusFilter = document.getElementById("status-filter");
                const searchInput = document.getElementById("search-input");
                const refreshToggle = document.getElementById("refresh-toggle");
                const statTraces = document.getElementById("stat-traces");
                const statErrorRate = document.getElementById("stat-error-rate");
                const statP95 = document.getElementById("stat-p95");
                const tooltip = document.getElementById("tooltip");
                const tracesView = document.getElementById("traces-view");
                const logsView = document.getElementById("logs-view");
                const logList = document.getElementById("log-list");
                const logsEmpty = document.getElementById("logs-empty");
                const logServiceFilter = document.getElementById("log-service-filter");
                const logSeverityFilter = document.getElementById("log-severity-filter");
                const logSearchInput = document.getElementById("log-search-input");
                const tabTraces = document.getElementById("tab-traces");
                const tabLogs = document.getElementById("tab-logs");

                // Helpers

                function relativeTimeNano(nanos) {
                    const ms = Number(nanos) / 1000000;
                    const now = Date.now();
                    const diffMs = now - ms;
                    if (isNaN(diffMs) || diffMs < 0) return "just now";
                    const seconds = Math.floor(diffMs / 1000);
                    if (seconds < 5) return "just now";
                    if (seconds < 60) return seconds + "s ago";
                    const minutes = Math.floor(seconds / 60);
                    if (minutes < 60) return minutes + "m ago";
                    const hours = Math.floor(minutes / 60);
                    if (hours < 24) return hours + "h ago";
                    const days = Math.floor(hours / 24);
                    return days + "d ago";
                }

                function formatDurationNano(nanos) {
                    if (nanos == null || nanos === 0) return "--";
                    const us = nanos / 1000;
                    if (us < 1000) return us.toFixed(0) + "\\u00B5s";
                    const ms = us / 1000;
                    if (ms < 1000) return ms.toFixed(1) + "ms";
                    const s = ms / 1000;
                    return s.toFixed(2) + "s";
                }

                function hasError(trace) {
                    return (trace.errorCount != null && trace.errorCount > 0) || trace.statusCode === 2;
                }

                const SPAN_KINDS = { 0: "UNSPECIFIED", 1: "INTERNAL", 2: "SERVER", 3: "CLIENT", 4: "PRODUCER", 5: "CONSUMER" };
                const STATUS_NAMES = { 0: "UNSET", 1: "OK", 2: "ERROR" };

                function spanKindName(kind) { return SPAN_KINDS[kind] || "INTERNAL"; }
                function statusName(code) { return STATUS_NAMES[code] || "OK"; }

                function demangleSwiftSymbol(sym) {
                    if (!sym.startsWith("$s") && !sym.startsWith("$S")) return null;
                    const parts = [];
                    let i = 2;
                    while (i < sym.length) {
                        let numStr = "";
                        while (i < sym.length && sym[i] >= "0" && sym[i] <= "9") {
                            numStr += sym[i]; i++;
                        }
                        if (!numStr) { i++; continue; }
                        const len = parseInt(numStr, 10);
                        if (len > 0 && i + len <= sym.length) {
                            const word = sym.substring(i, i + len);
                            if (/^[A-Za-z_]/.test(word)) parts.push(word);
                            i += len;
                        } else { break; }
                    }
                    return parts.length > 0 ? parts : null;
                }

                function demangleOperation(name) {
                    if (!name) return "unknown";
                    let sym = name.replace(/^trebuchet\\.(invoke|call)\\s+/, "");
                    const parts = demangleSwiftSymbol(sym);
                    if (parts) {
                        // [Module, Type, Method, params...]
                        if (parts.length >= 3) return parts[1] + "." + parts[2];
                        if (parts.length === 2) return parts.join(".");
                        return parts[0];
                    }
                    return name;
                }

                function demangleValue(val) {
                    if (typeof val !== "string") return String(val);
                    const parts = demangleSwiftSymbol(val);
                    if (parts && parts.length >= 3) {
                        return parts[1] + "." + parts[2] + "(" + parts.slice(3).join(", ") + ")";
                    } else if (parts && parts.length >= 2) {
                        return parts.join(".");
                    }
                    return val;
                }

                function formatDurationUs(us) {
                    if (us == null || isNaN(us)) return "--";
                    if (us < 1000) return us.toFixed(0) + "\\u00B5s";
                    const ms = us / 1000;
                    if (ms < 1000) return ms.toFixed(1) + "ms";
                    const s = ms / 1000;
                    return s.toFixed(2) + "s";
                }

                function parseAttributes(attrs) {
                    if (!attrs) return {};
                    if (typeof attrs === "object") return attrs;
                    try { return JSON.parse(attrs); } catch(e) { return {}; }
                }

                // API

                async function fetchStats() {
                    try {
                        const resp = await fetch("/api/stats?since=1440");
                        if (!resp.ok) return;
                        const data = await resp.json();
                        statTraces.textContent = data.totalCount != null ? data.totalCount.toLocaleString() : "--";
                        const rate = (data.totalCount > 0) ? (data.errorCount / data.totalCount * 100) : 0;
                        statErrorRate.textContent = rate.toFixed(1) + "%";
                        statErrorRate.classList.toggle("high", rate > 5);
                        statP95.textContent = data.p95DurationNano != null ? formatDurationNano(data.p95DurationNano) : "--";
                    } catch (e) {
                        // Silently ignore fetch errors
                    }
                }

                async function fetchServices() {
                    try {
                        const resp = await fetch("/api/services");
                        if (!resp.ok) return;
                        const data = await resp.json();
                        services = Array.isArray(data) ? data : (data.services || []);
                        renderServiceFilter();
                    } catch (e) {
                        // Silently ignore
                    }
                }

                async function fetchTraces() {
                    try {
                        const params = new URLSearchParams();
                        const svc = serviceFilter.value;
                        if (svc) params.set("service", svc);
                        const status = statusFilter.value;
                        if (status) params.set("status", status);
                        const search = searchInput.value.trim();
                        if (search) params.set("search", search);
                        params.set("limit", "50");

                        const url = "/api/traces" + (params.toString() ? "?" + params.toString() : "");
                        const resp = await fetch(url);
                        if (!resp.ok) return;
                        const data = await resp.json();
                        traces = Array.isArray(data) ? data : (data.traces || []);
                        renderTraces();
                    } catch (e) {
                        // Silently ignore
                    }
                }

                async function fetchTraceDetail(traceId) {
                    try {
                        const resp = await fetch("/api/traces/" + encodeURIComponent(traceId));
                        if (!resp.ok) return null;
                        return await resp.json();
                    } catch (e) {
                        return null;
                    }
                }

                // Rendering

                function renderServiceFilter() {
                    const current = serviceFilter.value;
                    serviceFilter.innerHTML = '<option value="">All Services</option>';
                    services.forEach(function(svc) {
                        const opt = document.createElement("option");
                        opt.value = svc;
                        opt.textContent = svc;
                        if (svc === current) opt.selected = true;
                        serviceFilter.appendChild(opt);
                    });
                }

                function renderTraces() {
                    traceTableBody.innerHTML = "";

                    if (traces.length === 0) {
                        emptyState.style.display = "block";
                        return;
                    }
                    emptyState.style.display = "none";

                    traces.forEach(function(trace) {
                        const isError = hasError(trace);
                        const isExpanded = trace.traceId === expandedTraceId;

                        // Trace summary row
                        const tr = document.createElement("tr");
                        tr.className = "trace-row" + (isError ? " error-row" : "") + (isExpanded ? " expanded" : "");
                        tr.setAttribute("data-trace-id", trace.traceId);

                        tr.innerHTML =
                            '<td class="time-cell">' + escapeHtml(relativeTimeNano(trace.startTimeNano)) + '</td>' +
                            '<td>' + escapeHtml(trace.serviceName || "--") + '</td>' +
                            '<td title="' + escapeHtml(trace.rootOperation || "") + '">' + escapeHtml(demangleOperation(trace.rootOperation)) + '</td>' +
                            '<td class="duration-cell">' + formatDurationNano(trace.durationNano) + '</td>' +
                            '<td><span class="status-dot' + (isError ? ' error' : '') + '"></span></td>' +
                            '<td class="spans-count">' + (trace.spanCount != null ? trace.spanCount : "--") + '</td>';

                        tr.addEventListener("click", function() {
                            toggleTraceDetail(trace.traceId);
                        });
                        traceTableBody.appendChild(tr);

                        // Detail row placeholder
                        const detailTr = document.createElement("tr");
                        detailTr.className = "trace-detail" + (isExpanded ? " open" : "");
                        detailTr.id = "detail-" + trace.traceId;
                        const detailTd = document.createElement("td");
                        detailTd.colSpan = 6;
                        detailTd.className = "trace-detail-inner";
                        if (isExpanded) {
                            detailTd.innerHTML = '<span>Loading...</span>';
                            loadAndRenderWaterfall(trace.traceId, detailTd);
                        }
                        detailTr.appendChild(detailTd);
                        traceTableBody.appendChild(detailTr);
                    });
                }

                function escapeHtml(str) {
                    const div = document.createElement("div");
                    div.appendChild(document.createTextNode(str || ""));
                    return div.innerHTML;
                }

                async function toggleTraceDetail(traceId) {
                    if (expandedTraceId === traceId) {
                        expandedTraceId = null;
                        renderTraces();
                        return;
                    }
                    expandedTraceId = traceId;
                    renderTraces();
                }

                async function loadAndRenderWaterfall(traceId, container) {
                    const detail = await fetchTraceDetail(traceId);
                    if (!detail) {
                        container.innerHTML = '<span style="color:var(--text-muted)">Failed to load trace detail.</span>';
                        return;
                    }

                    const spans = Array.isArray(detail) ? detail : (detail.spans || []);
                    if (spans.length === 0) {
                        container.innerHTML = '<span style="color:var(--text-muted)">No spans found.</span>';
                        return;
                    }

                    renderWaterfall(spans, container);
                }

                function buildSpanTree(spans) {
                    // Parse nanosecond timestamps to microseconds for display
                    const parsed = spans.map(function(s) {
                        const startUs = Number(s.startTimeNano) / 1000;
                        const endUs = s.endTimeNano ? Number(s.endTimeNano) / 1000 : startUs;
                        return Object.assign({}, s, {
                            _start: startUs,
                            _end: endUs,
                            _duration: endUs - startUs,
                            _children: []
                        });
                    });

                    const byId = {};
                    parsed.forEach(function(s) { byId[s.spanId] = s; });

                    const roots = [];
                    parsed.forEach(function(s) {
                        if (s.parentSpanId && byId[s.parentSpanId]) {
                            byId[s.parentSpanId]._children.push(s);
                        } else {
                            roots.push(s);
                        }
                    });

                    // Sort children by start time
                    function sortChildren(node) {
                        node._children.sort(function(a, b) { return a._start - b._start; });
                        node._children.forEach(sortChildren);
                    }
                    roots.sort(function(a, b) { return a._start - b._start; });
                    roots.forEach(sortChildren);

                    return roots;
                }

                function flattenTree(roots, depth) {
                    const result = [];
                    depth = depth || 0;
                    roots.forEach(function(node) {
                        result.push({ span: node, depth: depth });
                        result.push.apply(result, flattenTree(node._children, depth + 1));
                    });
                    return result;
                }

                function renderWaterfall(spans, container) {
                    const roots = buildSpanTree(spans);
                    const flat = flattenTree(roots, 0);

                    if (flat.length === 0) {
                        container.innerHTML = '<span style="color:var(--text-muted)">No spans to display.</span>';
                        return;
                    }

                    // Compute trace time bounds
                    let traceStart = Infinity;
                    let traceEnd = -Infinity;
                    flat.forEach(function(item) {
                        if (item.span._start < traceStart) traceStart = item.span._start;
                        if (item.span._end > traceEnd) traceEnd = item.span._end;
                    });
                    const traceDuration = Math.max(traceEnd - traceStart, 1);

                    container.innerHTML = "";

                    // Header
                    const header = document.createElement("div");
                    header.className = "waterfall-header";
                    header.innerHTML =
                        '<div class="waterfall-header-label name-col">Span</div>' +
                        '<div class="waterfall-header-label bar-col">' + formatDurationUs(traceDuration) + '</div>';
                    container.appendChild(header);

                    // Rows
                    flat.forEach(function(item) {
                        const span = item.span;
                        const depth = item.depth;
                        const offsetPct = ((span._start - traceStart) / traceDuration) * 100;
                        const widthPct = Math.max((span._duration / traceDuration) * 100, 0.3);
                        const isError = span.statusCode != null && span.statusCode >= 2;
                        const isClient = span.spanKind === 3;

                        const row = document.createElement("div");
                        row.className = "waterfall-row";

                        // Label
                        const label = document.createElement("div");
                        label.className = "waterfall-label";
                        label.style.paddingLeft = (8 + depth * 20) + "px";

                        const kindStr = spanKindName(span.spanKind);
                        const kindBadge = document.createElement("span");
                        kindBadge.className = "span-kind-badge";
                        kindBadge.textContent = kindStr.substring(0, 3);

                        const nameText = document.createElement("span");
                        nameText.className = "waterfall-label-text";
                        nameText.textContent = demangleOperation(span.operationName || span.spanId);

                        label.appendChild(kindBadge);
                        label.appendChild(nameText);
                        row.appendChild(label);

                        // Bar area
                        const barArea = document.createElement("div");
                        barArea.className = "waterfall-bar-area";

                        const bar = document.createElement("div");
                        bar.className = "waterfall-bar" + (isError ? " error" : (isClient ? " client" : " ok"));
                        bar.style.left = offsetPct + "%";
                        bar.style.width = widthPct + "%";
                        barArea.appendChild(bar);

                        // Duration label after bar
                        const durLabel = document.createElement("span");
                        durLabel.className = "waterfall-bar-duration";
                        durLabel.textContent = formatDurationUs(span._duration);
                        durLabel.style.left = (offsetPct + widthPct + 0.5) + "%";
                        barArea.appendChild(durLabel);

                        row.appendChild(barArea);

                        // Tooltip events
                        row.addEventListener("mouseenter", function(e) {
                            showTooltip(e, span);
                        });
                        row.addEventListener("mousemove", function(e) {
                            positionTooltip(e);
                        });
                        row.addEventListener("mouseleave", function() {
                            hideTooltip();
                        });

                        container.appendChild(row);
                    });

                    // Time markers
                    const markers = document.createElement("div");
                    markers.className = "waterfall-time-markers";
                    const steps = [0, 0.25, 0.5, 0.75, 1.0];
                    steps.forEach(function(pct) {
                        const m = document.createElement("span");
                        m.className = "waterfall-time-marker";
                        m.textContent = formatDurationUs(pct * traceDuration);
                        markers.appendChild(m);
                    });
                    container.appendChild(markers);
                }

                // Tooltip

                function showTooltip(e, span) {
                    let html = '<div class="tooltip-title">' + escapeHtml(demangleOperation(span.operationName || span.spanId)) + '</div>';
                    html += '<div class="tooltip-row"><span class="tooltip-key">Duration</span><span class="tooltip-value">' + formatDurationUs(span._duration) + '</span></div>';
                    html += '<div class="tooltip-row"><span class="tooltip-key">Kind</span><span class="tooltip-value">' + escapeHtml(spanKindName(span.spanKind)) + '</span></div>';
                    html += '<div class="tooltip-row"><span class="tooltip-key">Status</span><span class="tooltip-value">' + escapeHtml(statusName(span.statusCode)) + '</span></div>';

                    const attrs = parseAttributes(span.attributes);
                    const attrKeys = Object.keys(attrs);
                    if (attrKeys.length > 0) {
                        html += '<div class="tooltip-attrs">';
                        attrKeys.slice(0, 8).forEach(function(key) {
                            const displayVal = (key === "rpc.method") ? demangleValue(attrs[key]) : String(attrs[key]);
                            html += '<div class="tooltip-row"><span class="tooltip-key">' + escapeHtml(key) + '</span><span class="tooltip-value">' + escapeHtml(displayVal) + '</span></div>';
                        });
                        if (attrKeys.length > 8) {
                            html += '<div class="tooltip-row"><span class="tooltip-key" style="font-style:italic">+ ' + (attrKeys.length - 8) + ' more</span><span></span></div>';
                        }
                        html += '</div>';
                    }

                    tooltip.innerHTML = html;
                    tooltip.classList.add("visible");
                    positionTooltip(e);
                }

                function positionTooltip(e) {
                    const x = e.clientX + 12;
                    const y = e.clientY + 12;
                    const rect = tooltip.getBoundingClientRect();
                    const maxX = window.innerWidth - rect.width - 8;
                    const maxY = window.innerHeight - rect.height - 8;
                    tooltip.style.left = Math.min(x, maxX) + "px";
                    tooltip.style.top = Math.min(y, maxY) + "px";
                }

                function hideTooltip() {
                    tooltip.classList.remove("visible");
                }

                // Tabs

                function switchTab(tab) {
                    activeTab = tab;
                    tabTraces.classList.toggle("active", tab === "traces");
                    tabLogs.classList.toggle("active", tab === "logs");
                    tracesView.style.display = tab === "traces" ? "block" : "none";
                    logsView.classList.toggle("active", tab === "logs");
                    if (tab === "logs") {
                        renderLogServiceFilter();
                        fetchLogs();
                    }
                }

                tabTraces.addEventListener("click", function() { switchTab("traces"); });
                tabLogs.addEventListener("click", function() { switchTab("logs"); });

                // Logs API

                async function fetchLogs(append) {
                    try {
                        const params = new URLSearchParams();
                        const svc = logServiceFilter.value;
                        if (svc) params.set("service", svc);
                        const sev = logSeverityFilter.value;
                        if (sev) params.set("severity", sev);
                        const q = logSearchInput.value.trim();
                        if (q) params.set("search", q);
                        params.set("limit", "100");
                        if (append && logNextCursor) params.set("cursor", logNextCursor);

                        const url = "/api/logs" + (params.toString() ? "?" + params.toString() : "");
                        const resp = await fetch(url);
                        if (!resp.ok) return;
                        const data = await resp.json();
                        const newLogs = data.logs || [];
                        logNextCursor = data.nextCursor || null;

                        if (append) {
                            logs = logs.concat(newLogs);
                        } else {
                            logs = newLogs;
                        }
                        renderLogs(append);
                    } catch (e) {
                        // Silently ignore
                    }
                }

                // Log rendering

                function severityClass(num) {
                    if (num >= 21) return "fatal";
                    if (num >= 17) return "error";
                    if (num >= 13) return "warn";
                    if (num >= 9) return "info";
                    if (num >= 5) return "debug";
                    return "trace-sev";
                }

                function renderLogs(append) {
                    if (!append) {
                        logList.innerHTML = "";
                    }

                    if (logs.length === 0) {
                        logsEmpty.style.display = "block";
                        return;
                    }
                    logsEmpty.style.display = "none";

                    const startIdx = append ? (logs.length - (logs.length - logList.children.length)) : 0;
                    // Remove existing load-more button
                    const existingBtn = logList.querySelector(".logs-load-more");
                    if (existingBtn) existingBtn.remove();

                    const fragment = document.createDocumentFragment();
                    const renderFrom = append ? logList.children.length : 0;

                    for (let i = renderFrom; i < logs.length; i++) {
                        const log = logs[i];
                        const entry = document.createElement("div");
                        entry.className = "log-entry" + (log.traceId ? " has-trace" : "");

                        const ts = document.createElement("span");
                        ts.className = "log-timestamp";
                        ts.textContent = relativeTimeNano(log.timestamp);

                        const sev = document.createElement("span");
                        sev.className = "log-severity " + severityClass(log.severityNumber);
                        sev.textContent = log.severityText || "??";

                        const svc = document.createElement("span");
                        svc.className = "log-service";
                        svc.textContent = log.serviceName || "--";

                        const body = document.createElement("span");
                        body.className = "log-body";
                        body.textContent = log.body || "";

                        entry.appendChild(ts);
                        entry.appendChild(sev);
                        entry.appendChild(svc);
                        entry.appendChild(body);

                        if (log.traceId) {
                            const link = document.createElement("span");
                            link.className = "log-trace-link";
                            link.textContent = "trace";
                            entry.appendChild(link);

                            entry.addEventListener("click", (function(tid) {
                                return function() {
                                    expandedTraceId = tid;
                                    switchTab("traces");
                                    fetchTraces();
                                };
                            })(log.traceId));
                        }

                        fragment.appendChild(entry);
                    }

                    logList.appendChild(fragment);

                    if (logNextCursor) {
                        const btn = document.createElement("button");
                        btn.className = "logs-load-more";
                        btn.textContent = "Load more";
                        btn.addEventListener("click", function() {
                            fetchLogs(true);
                        });
                        logList.appendChild(btn);
                    }
                }

                function renderLogServiceFilter() {
                    const current = logServiceFilter.value;
                    logServiceFilter.innerHTML = '<option value="">All Services</option>';
                    services.forEach(function(svc) {
                        const opt = document.createElement("option");
                        opt.value = svc;
                        opt.textContent = svc;
                        if (svc === current) opt.selected = true;
                        logServiceFilter.appendChild(opt);
                    });
                }

                logServiceFilter.addEventListener("change", function() {
                    logNextCursor = null;
                    fetchLogs();
                });

                logSeverityFilter.addEventListener("change", function() {
                    logNextCursor = null;
                    fetchLogs();
                });

                let logSearchTimeout = null;
                logSearchInput.addEventListener("input", function() {
                    clearTimeout(logSearchTimeout);
                    logSearchTimeout = setTimeout(function() {
                        logNextCursor = null;
                        fetchLogs();
                    }, 300);
                });

                // Auto-refresh

                function setAutoRefresh(enabled) {
                    autoRefresh = enabled;
                    refreshToggle.classList.toggle("active", enabled);
                    if (refreshInterval) {
                        clearInterval(refreshInterval);
                        refreshInterval = null;
                    }
                    if (enabled) {
                        refreshInterval = setInterval(refreshAll, 5000);
                    }
                }

                // Controls

                refreshToggle.addEventListener("click", function() {
                    setAutoRefresh(!autoRefresh);
                });

                serviceFilter.addEventListener("change", function() {
                    expandedTraceId = null;
                    fetchTraces();
                });

                statusFilter.addEventListener("change", function() {
                    expandedTraceId = null;
                    fetchTraces();
                });

                let searchTimeout = null;
                searchInput.addEventListener("input", function() {
                    clearTimeout(searchTimeout);
                    searchTimeout = setTimeout(function() {
                        expandedTraceId = null;
                        fetchTraces();
                    }, 300);
                });

                // Init

                function refreshAll() {
                    fetchStats();
                    if (activeTab === "traces") {
                        fetchTraces();
                    } else {
                        logNextCursor = null;
                        fetchLogs();
                    }
                }

                function init() {
                    fetchStats();
                    fetchServices();
                    fetchTraces();
                }

                init();
            })();
        </script>
    </body>
    </html>
    """

    public static let loginHTML: String = loginHTML(error: nil)

    public static func loginHTML(error: String?) -> String {
        let errorBlock = error.map { msg in
            """
            <div style="background:rgba(231,76,60,0.15);border:1px solid var(--error);border-radius:8px;padding:10px 14px;margin-bottom:16px;font-size:13px;color:var(--error);">\(msg)</div>
            """
        } ?? ""

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Sign in — TrebuchetOTel</title>
            <style>
                :root {
                    --bg: #1a1a2e;
                    --surface: #16213e;
                    --text: #e0e0e0;
                    --text-muted: #8892a0;
                    --accent: #0f3460;
                    --success: #4ecca3;
                    --error: #e74c3c;
                    --border: #2a2a4a;
                    --client: #3498db;
                }

                * { margin: 0; padding: 0; box-sizing: border-box; }

                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    background: var(--bg);
                    color: var(--text);
                    min-height: 100vh;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                }

                .login-card {
                    background: var(--surface);
                    border: 1px solid var(--border);
                    border-radius: 12px;
                    padding: 32px;
                    width: 100%;
                    max-width: 380px;
                    margin: 24px;
                }

                .login-title {
                    font-size: 20px;
                    font-weight: 700;
                    margin-bottom: 6px;
                    display: flex;
                    align-items: center;
                    gap: 8px;
                }

                .login-subtitle {
                    font-size: 13px;
                    color: var(--text-muted);
                    margin-bottom: 24px;
                }

                .login-label {
                    font-size: 12px;
                    font-weight: 600;
                    text-transform: uppercase;
                    letter-spacing: 0.5px;
                    color: var(--text-muted);
                    margin-bottom: 6px;
                    display: block;
                }

                .login-input {
                    width: 100%;
                    background: var(--accent);
                    color: var(--text);
                    border: 1px solid var(--border);
                    border-radius: 8px;
                    padding: 10px 14px;
                    font-size: 14px;
                    font-family: "SF Mono", "Fira Code", monospace;
                    outline: none;
                    transition: border-color 0.15s;
                    margin-bottom: 20px;
                }

                .login-input:focus {
                    border-color: var(--client);
                }

                .login-button {
                    width: 100%;
                    background: var(--client);
                    color: #fff;
                    border: none;
                    border-radius: 8px;
                    padding: 10px;
                    font-size: 14px;
                    font-weight: 600;
                    cursor: pointer;
                    transition: opacity 0.15s;
                }

                .login-button:hover {
                    opacity: 0.9;
                }
            </style>
        </head>
        <body>
            <div class="login-card">
                <div class="login-title">&#x1F3F0; TrebuchetOTel</div>
                <div class="login-subtitle">Enter your auth token to access the dashboard.</div>
                \(errorBlock)
                <form method="POST" action="/login">
                    <label class="login-label" for="token">Auth Token</label>
                    <input class="login-input" type="password" id="token" name="token" placeholder="OTEL_AUTH_TOKEN" autofocus required />
                    <button class="login-button" type="submit">Sign in</button>
                </form>
            </div>
        </body>
        </html>
        """
    }
}
