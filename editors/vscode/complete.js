// Static completions for Orbit. There is no language server, so everything
// here is a closed list taken from the compiler by hand; each list cites the
// source to re-check. Takes `vscode` as a parameter and never requires it, so
// `node test/extension_test.js` can drive buildCompletions with a stub.
//
// Deliberately absent: null, loop{}, Option<T>, sockets,
// readLine/println, req.path/req.method, system.* beyond the 8 counters.
// Completing those would manufacture a compile error.

'use strict';

// std/**/*.orb, all 14 modules. Detail lines name the LANGUAGE_REFERENCE.md
// standard-library section. Removed modules are never listed:
// std/core/result.orb, std/sys/crypto/hash.orb, std/sys/bytes/buffer.orb,
// std/sys/net/socket.orb (see the cryptography section + std/quarantine/README.md).
const STD_MODULES = [
    { path: 'std/test/assert.orb', detail: 'assertTrue, assertEqInt, assertEqStr' },
    { path: 'std/string/string.orb', detail: 'trim, split, join, toUpper, toLower, parseIntChecked, .to_int()' },
    { path: 'std/hash/hash.orb', detail: 'sha256Hex, hmacSha256' },
    { path: 'std/collections/lists.orb', detail: 'getOr, firstOr, lastOr, listContains, listIndexOf, reverse (generic); containsStr/Int, indexOfStr/Int shims' },
    { path: 'std/fs/file.orb', detail: 'readAll, writeAll, append, exists, removeFile, listDir' },
    { path: 'std/io/io.orb', detail: 'supportsColor, gradient' },
    { path: 'std/time/time.orb', detail: 'uptimeSeconds, addSeconds, elapsedSince, deadlineExceededSeconds' },
    { path: 'std/sys/proc/process.orb', detail: 'pid, getEnv, getEnvOrDefault, execStatus, exitProcess' },
    { path: 'std/log/log.orb', detail: 'info, warn, error, debug, withReq, toJsonLine' },
    { path: 'std/json/json.orb', detail: 'jsonQuote (escape a string for hand-built bodies)' },
    { path: 'std/sys/crypto/jwt.orb', detail: 'signHs256, verifyHs256, decodePayload, getExp, verifyWithKeys' },
    { path: 'std/bytes/bytes.orb', detail: 'newBuffer, appendByte/Slice, writeFrame/readFrame, readAt (-1 OOR)' },
    { path: 'std/sys/term/color.orb', detail: 'wrapRgbForeground + styling' },
    { path: 'std/convert/convert.orb', detail: 'see LANGUAGE_REFERENCE standard library' },
];

// compiler/builder.orb req members. Only these 8 lower to builtins.
const REQ_MEMBERS = [
    { label: 'param', detail: 'req.param("name") -> string; reads a :id/{id} capture' },
    { label: 'query', detail: 'req.query("key") -> string' },
    { label: 'body', detail: 'req.body() -> string (json() is an alias)' },
    { label: 'header', detail: 'req.header("name") -> string' },
    { label: 'bearer_token', detail: 'req.bearer_token() -> string' },
    { label: 'has_role', detail: 'req.has_role("admin") -> bool' },
    { label: 'role', detail: 'req.role() -> string' },
    { label: 'file', detail: 'req.file(field, dir) -> string; saves a multipart upload' },
];

// compiler/builder.orb system counters. All () -> int; no success/error split.
const SYSTEM_MEMBERS = [
    { label: 'uptime', detail: 'system.uptime() -> int; seconds since process start' },
    { label: 'pid', detail: 'system.pid() -> int' },
    { label: 'active_workers', detail: 'system.active_workers() -> int (0 outside servers)' },
    { label: 'http_requests_total', detail: 'system.http_requests_total() -> int' },
    { label: 'latency_avg_us', detail: 'system.latency_avg_us() -> int' },
    { label: 'latency_p50_us', detail: 'system.latency_p50_us() -> int; bucket edge' },
    { label: 'latency_p95_us', detail: 'system.latency_p95_us() -> int; bucket edge' },
    { label: 'latency_p99_us', detail: 'system.latency_p99_us() -> int; bucket edge' },
];

// compiler/builder.orb model ORM surface.
const MODEL_METHODS = [
    { label: 'all', detail: 'Note.all() — every row' },
    { label: 'where', detail: 'Note.where("author_id = ?", who) — 2-arg form is parameterized' },
    { label: 'find', detail: 'Note.find(id)' },
    { label: 'create', detail: 'Note.create(payload) — true unless the id exists' },
    { label: 'delete', detail: 'Note.delete(id) — true only if a row was removed' },
];

// compiler/lexer.orb matchKeyword. `loop` (reserved, body is a parse error),
// `with` (reserved-unused) and `then` (contextual identifier) excluded.
const KEYWORDS = [
    'fn', 'val', 'var', 'mut', 'const', 'private', 'extern', 'async',
    'model', 'route', 'type', 'enum', 'union', 'trait', 'impl', 'every',
    'import', 'use', 'if', 'else', 'for', 'in', 'while', 'break',
    'continue', 'return', 'match', 'try', 'catch', 'ok', 'err',
];

const TYPES = [
    'int', 'float', 'string', 'bool', 'void', 'list', 'map', 'object',
    'result', 'response', 'List', 'Map', 'Result', 'Response',
];

const HTTP_METHODS = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'];

const BUILTINS = [
    { label: 'print', detail: 'print(x) — one arg, newlines; truncates floats' },
    { label: 'ok', detail: 'ok(v) — result value; bind first in -> result fns, never return ok(expr)' },
    { label: 'err', detail: 'err("msg", code) — result value; route form is err 400 "msg"' },
];

const LIST_METHODS = [
    { label: 'push', detail: 'first push decides list<T> when undeclared' },
    { label: 'get', detail: '.get(i) — the bounds-checked accessor (NULL past the end)' },
    { label: 'at', detail: '.at(i) — same element, typed' },
    { label: 'pop', detail: '.pop() — same element, typed' },
    { label: 'len', detail: '.len() -> int' },
];

function item(vscode, label, kind, detail, sortText, insertText) {
    const c = new vscode.CompletionItem(label, kind);
    c.detail = detail;
    c.sortText = sortText;
    if (insertText !== undefined) {
        c.insertText = insertText;
    }
    return c;
}

// Pure function of the line prefix: contexts are regexes, no parsing.
function buildCompletions(vscode, linePrefix) {
    const K = vscode.CompletionItemKind;

    // Inside an import string: only real std paths.
    if (/import\s+"[^"]*$/.test(linePrefix)) {
        return STD_MODULES.map(m =>
            item(vscode, m.path, K.Module, m.detail, '0_' + m.path));
    }

    if (/req\.$/.test(linePrefix)) {
        return REQ_MEMBERS.map(m =>
            item(vscode, m.label, K.Method, m.detail, '0_' + m.label));
    }
    if (/system\.$/.test(linePrefix)) {
        return SYSTEM_MEMBERS.map(m =>
            item(vscode, m.label, K.Property, m.detail, '0_' + m.label));
    }
    const model = linePrefix.match(/([A-Z][A-Za-z0-9_]*)\.$/);
    if (model && model[1] !== 'List' && model[1] !== 'Map' &&
        model[1] !== 'Result' && model[1] !== 'Response') {
        return MODEL_METHODS.map(m =>
            item(vscode, m.label, K.Method, m.detail, '0_' + m.label));
    }
    // HTTP methods only right after `route ` at statement head.
    if (/^\s*route\s+[A-Z]*$/.test(linePrefix)) {
        return HTTP_METHODS.map(m =>
            item(vscode, m, K.EnumMember, 'Route method', '0_' + m));
    }

    const out = [];
    for (const k of KEYWORDS) {
        out.push(item(vscode, k, K.Keyword, 'Orbit keyword', '1_' + k));
    }
    for (const t of TYPES) {
        out.push(item(vscode, t, K.Class,
            'Orbit type (other capitals like Int are E1006)', '2_' + t));
    }
    for (const b of BUILTINS) {
        out.push(item(vscode, b.label, K.Function, b.detail, '3_' + b.label));
    }
    for (const m of LIST_METHODS) {
        out.push(item(vscode, m.label, K.Function, m.detail, '3_' + m.label));
    }
    for (const c of ['true', 'false']) {
        out.push(item(vscode, c, K.Constant, 'Boolean literal', '2_' + c));
    }
    return out;
}

function registerCompletionProvider(vscode, context) {
    context.subscriptions.push(
        vscode.languages.registerCompletionItemProvider(
            { language: 'orbit', scheme: 'file' },
            {
                provideCompletionItems(document, position) {
                    const line = document.lineAt(position).text.slice(0, position.character);
                    return buildCompletions(vscode, line);
                },
            },
            '.', '"', '/', ':'
        )
    );
}

module.exports = {
    buildCompletions,
    registerCompletionProvider,
    STD_MODULES,
    REQ_MEMBERS,
    SYSTEM_MEMBERS,
    MODEL_METHODS,
    KEYWORDS,
    TYPES,
};
