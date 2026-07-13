/**
 * @file  pulse.c
 * @brief Real-time telemetry dashboard engine for Orbit.
 *
 * Serves a self-contained HTML dashboard at /_pulse and a JSON data endpoint
 * at /_pulse/data.  All assets are embedded as string literals so the binary
 * has zero external file dependencies.  Telemetry is read atomically from the
 * global OrbitPerfStats structure and rendered via a single snprintf call.
 */
#ifndef ORBIT_PULSE_C
#define ORBIT_PULSE_C

#include "performance.h"
#include "kynx.c"
#include "arena_pool.c"
#include <stdio.h>

/* ──────────────────────────────────────────────────────────────────────
 * Orbit Pulse — Real-time telemetry engine.
 *
 * Serves a stunning dashboard at /_pulse and a JSON API at /_pulse/data.
 * Zero external dependencies; all assets are embedded.
 * ────────────────────────────────────────────────────────────────────── */

// Forward declaration of the dashboard HTML
extern const char* ORBIT_PULSE_DASHBOARD_HTML;

/** @brief Build a JSON object containing a snapshot of current system telemetry; all allocations come from @p arena. */
orbit_string orbit_pulse_get_stats_json(OrbitArena* arena) {
    OrbitPerfStats stats = orbit_perf_get_stats();
    
    // Calculate averages (avoid division by zero)
    uint64_t avg_cycles = stats.request_count > 0 ? stats.total_cycles / stats.request_count : 0;
    
    // We are basically formatting a JSON string into the arena
    // In a real implementation we'd use a JSON builder, but a clean snprintf is fine for fixed schema
    char* buf = (char*)orbit_alloc(arena, 4096);
    snprintf(buf, 4096,
        "{"
        "\"requests\":{\"total\":%llu,\"avg_cycles\":%llu,\"min\":%llu,\"max\":%llu},"
        "\"memory\":{\"reuse\":%llu,\"alloc_mb\":%.2f,\"active_arenas\":%u},"
        "\"security\":{\"blocks\":%llu,\"tracked_ips\":%u},"
        "\"database\":{\"queries\":%llu,\"total_cycles\":%llu},"
        "\"interning\":{\"hits\":%llu}"
        "}",
        stats.request_count, avg_cycles, stats.min_cycles, stats.max_cycles,
        stats.arena_reuse_count, (double)stats.total_alloc_bytes / (1024.0 * 1024.0), stats.active_arenas,
        stats.kynx_blocks, stats.kynx_tracked_ips,
        stats.db_queries, stats.db_total_cycles,
        stats.string_intern_hits
    );
    
    return buf;
}

const char* ORBIT_PULSE_DASHBOARD_HTML = 
"<!DOCTYPE html>"
"<html lang='en'>"
"<head>"
"    <meta charset='UTF-8'>"
"    <meta name='viewport' content='width=device-width, initial-scale=1.0'>"
"    <title>Orbit Pulse | Engine Telemetry</title>"
"    <link href='https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;700&display=swap' rel='stylesheet'>"
"    <style>"
"        :root {"
"            --bg: #050505;"
"            --accent: #00f2ff;"
"            --glass: rgba(255, 255, 255, 0.03);"
"            --border: rgba(255, 255, 255, 0.1);"
"            --text: #ffffff;"
"            --text-dim: #888;"
"        }"
"        * { margin: 0; padding: 0; box-sizing: border-box; }"
"        body {"
"            background: var(--bg);"
"            color: var(--text);"
"            font-family: 'Outfit', sans-serif;"
"            min-height: 100vh;"
"            padding: 40px;"
"            overflow-x: hidden;"
"        }"
"        .header {"
"            display: flex;"
"            justify-content: space-between;"
"            align-items: center;"
"            margin-bottom: 60px;"
"        }"
"        .logo {"
"            font-size: 24px;"
"            font-weight: 700;"
"            letter-spacing: -1px;"
"            display: flex;"
"            align-items: center;"
"            gap: 12px;"
"        }"
"        .logo span { color: var(--accent); }"
"        .status {"
"            padding: 8px 16px;"
"            background: rgba(0, 255, 100, 0.1);"
"            border: 1px solid rgba(0, 255, 100, 0.2);"
"            border-radius: 20px;"
"            font-size: 12px;"
"            color: #00ff64;"
"            display: flex;"
"            align-items: center;"
"            gap: 8px;"
"        }"
"        .status::before {"
"            content: '';"
"            width: 8px;"
"            height: 8px;"
"            background: #00ff64;"
"            border-radius: 50%;"
"            box-shadow: 0 0 10px #00ff64;"
"            animation: pulse 2s infinite;"
"        }"
"        @keyframes pulse { 0% { opacity: 1; } 50% { opacity: 0.3; } 100% { opacity: 1; } }"
"        .grid {"
"            display: grid;"
"            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));"
"            gap: 24px;"
"        }"
"        .card {"
"            background: var(--glass);"
"            backdrop-filter: blur(20px);"
"            border: 1px solid var(--border);"
"            border-radius: 24px;"
"            padding: 32px;"
"            transition: all 0.4s cubic-bezier(0.16, 1, 0.3, 1);"
"            position: relative;"
"            overflow: hidden;"
"        }"
"        .card:hover {"
"            border-color: var(--accent);"
"            transform: translateY(-5px);"
"        }"
"        .card::after {"
"            content: '';"
"            position: absolute;"
"            top: 0; left: 0; width: 100%; height: 100%;"
"            background: radial-gradient(circle at 50% 0%, rgba(0, 242, 255, 0.05), transparent 70%);"
"            opacity: 0;"
"            transition: opacity 0.4s;"
"        }"
"        .card:hover::after { opacity: 1; }"
"        .card-label {"
"            color: var(--text-dim);"
"            font-size: 14px;"
"            text-transform: uppercase;"
"            letter-spacing: 2px;"
"            margin-bottom: 24px;"
"        }"
"        .card-value {"
"            font-size: 48px;"
"            font-weight: 700;"
"            margin-bottom: 8px;"
"        }"
"        .card-sub {"
"            color: var(--text-dim);"
"            font-size: 14px;"
"        }"
"        .accent-text { color: var(--accent); }"
"        .stat-group {"
"            display: flex;"
"            flex-direction: column;"
"            gap: 12px;"
"        }"
"        .stat-row {"
"            display: flex;"
"            justify-content: space-between;"
"            font-size: 15px;"
"        }"
"        .stat-row span:last-child { font-weight: 700; }"
"        #canvas-perf { width: 100%; height: 60px; margin-top: 20px; }"
"    </style>"
"</head>"
"<body>"
"    <div class='header'>"
"        <div class='logo'>ORBIT <span>PULSE</span></div>"
"        <div class='status'>SYSTEM ONLINE</div>"
"    </div>"
"    <div class='grid'>"
"        <div class='card'>"
"            <div class='card-label'>Traffic</div>"
"            <div class='card-value' id='req-total'>0</div>"
"            <div class='card-sub'>TOTAL REQUESTS PROCESSED</div>"
"        </div>"
"        <div class='card'>"
"            <div class='card-label'>Latency</div>"
"            <div class='card-value accent-text' id='req-avg'>0<span style='font-size:24px'> MC</span></div>"
"            <div class='card-sub'>AVERAGE CPU CYCLES PER REQ</div>"
"        </div>"
"        <div class='card'>"
"            <div class='card-label'>Memory</div>"
"            <div class='card-value' id='mem-alloc'>0.00<span style='font-size:24px'> MB</span></div>"
"            <div class='card-sub' id='mem-arenas'>0 ACTIVE ARENAS</div>"
"        </div>"
"        <div class='card'>"
"            <div class='card-label'>Orbit Kynx</div>"
"            <div class='card-value' id='sec-blocks' style='color:#ff3e3e'>0</div>"
"            <div class='card-sub' id='sec-ips'>0 THREATS MITIGATED</div>"
"        </div>"
"        <div class='card'>"
"            <div class='card-label'>Database</div>"
"            <div class='card-value' id='db-queries'>0</div>"
"            <div class='card-sub'>DATABASE OPERATIONS</div>"
"        </div>"
"        <div class='card'>"
"            <div class='card-label'>Symbols</div>"
"            <div class='card-value' id='intern-hits'>0</div>"
"            <div class='card-sub'>INTERNED SYMBOL HITS</div>"
"        </div>"
"    </div>"
"    <script>"
"        async function updatePulse() {"
"            try {"
"                const r = await fetch('/_pulse/data');"
"                const d = await r.json();"
"                document.getElementById('req-total').innerText = d.requests.total.toLocaleString();"
"                document.getElementById('req-avg').innerHTML = (d.requests.avg_cycles / 1000).toFixed(1) + '<span style=\"font-size:24px\"> KC</span>';"
"                document.getElementById('mem-alloc').innerHTML = d.memory.alloc_mb.toFixed(2) + '<span style=\"font-size:24px\"> MB</span>';"
"                document.getElementById('mem-arenas').innerText = d.memory.active_arenas + ' ACTIVE ARENAS (REUSE: ' + d.memory.reuse + ')';"
"                document.getElementById('sec-blocks').innerText = d.security.blocks.toLocaleString();"
"                document.getElementById('sec-ips').innerText = d.security.tracked_ips + ' NODES TRACKED BY KYNX';"
"                document.getElementById('db-queries').innerText = d.database.queries.toLocaleString();"
"                document.getElementById('intern-hits').innerText = d.interning.hits.toLocaleString();"
"            } catch(e) { console.error('Pulse Sync Failure', e); }"
"        }"
"        setInterval(updatePulse, 1000);"
"        updatePulse();"
"    </script>"
"</body>"
"</html>";

#endif
