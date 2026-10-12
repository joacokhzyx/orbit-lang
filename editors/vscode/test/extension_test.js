// node editors/vscode/test/extension_test.js
//
// Unit tests for extension.js pure helpers and complete.js provider logic.
// `vscode` does not exist outside the editor, so it is stubbed through
// Module.require before extension.js loads. No test framework, same style
// as diagnostics_test.js.

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const Module = require('module');

class Position {
    constructor(line, character) {
        this.line = line;
        this.character = character;
    }
}
class Range {
    constructor(start, end) {
        this.start = start;
        this.end = end;
    }
}
class Diagnostic {
    constructor(range, message, severity) {
        this.range = range;
        this.message = message;
        this.severity = severity;
    }
}

let folders = [];
const vscodeStub = {
    Position,
    Range,
    Diagnostic,
    DiagnosticSeverity: { Error: 0 },
    CompletionItemKind: {
        Keyword: 1, Class: 2, Function: 3, Constant: 4,
        Method: 5, Property: 6, Module: 7, EnumMember: 8,
    },
    CompletionItem: class {
        constructor(label, kind) {
            this.label = label;
            this.kind = kind;
        }
    },
    workspace: {
        get workspaceFolders() {
            return folders;
        },
        getConfiguration: () => ({ get: (key, def) => def }),
    },
};

const origRequire = Module.prototype.require;
Module.prototype.require = function (id, ...rest) {
    if (id === 'vscode') {
        return vscodeStub;
    }
    return origRequire.call(this, id, ...rest);
};

const ext = require('../extension.js');
const complete = require('../complete.js');

let failures = 0;
function test(name, fn) {
    try {
        fn();
        console.log('ok   ' + name);
    } catch (err) {
        failures++;
        console.log('FAIL ' + name);
        console.log('     ' + err.message);
    }
}

test('position-less diagnostic anchors at file top', () => {
    const out = ext.toVscodeDiagnostics([
        { code: 'orbit-semantic', message: 'Return type mismatch', line: null, column: null },
    ]);
    assert.strictEqual(out.length, 1);
    assert.deepStrictEqual(out[0].range.start, new Position(0, 0));
    assert.strictEqual(out[0].source, 'orbit-semantic');
    assert.strictEqual(out[0].severity, 0);
});

test('parser position converts to zero-based with one-char range', () => {
    const out = ext.toVscodeDiagnostics([
        { code: 'orbit-E0301', message: "unexpected token 'CloseBrace'", line: 0, column: 33 },
    ]);
    assert.deepStrictEqual(out[0].range.start, new Position(0, 33));
    assert.deepStrictEqual(out[0].range.end, new Position(0, 34));
});

test('skipped-check detector catches non-diagnostic output', () => {
    assert.ok(ext.isSkippedCheck('Usage: orbit check <file.orb> [--quiet]'));
    assert.ok(ext.isSkippedCheck("orbit check: could not read input file 'x'."));
    assert.ok(ext.isSkippedCheck('Unknown command: lsp\nUsage: orbit <command>'));
    assert.ok(!ext.isSkippedCheck("error[E0301]: unexpected token 'CloseBrace'\n  --> d.orb:1:34"));
    assert.ok(!ext.isSkippedCheck('Semantic error: Return type mismatch'));
});

test('untitled documents are detected', () => {
    assert.ok(ext.isUntitled({ isUntitled: true, uri: { scheme: 'untitled' } }));
    assert.ok(ext.isUntitled({ isUntitled: false, uri: { scheme: 'untitled' } }));
    assert.ok(!ext.isUntitled({ isUntitled: false, uri: { scheme: 'file' } }));
});

test('findOnPath finds the exact binary name', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orbit-path-'));
    const exeName = os.platform() === 'win32' ? 'orbit.exe' : 'orbit';
    fs.writeFileSync(path.join(dir, exeName), 'fake');
    const oldPath = process.env.PATH || '';
    const oldExt = process.env.PATHEXT;
    try {
        process.env.PATH = dir + (os.platform() === 'win32' ? ';' : ':') + oldPath;
        if (os.platform() === 'win32') {
            process.env.PATHEXT = '.COM;.EXE;.BAT;.CMD';
        }
        const found = ext.findOnPath(exeName);
        assert.strictEqual(found, path.join(dir, exeName));
    } finally {
        process.env.PATH = oldPath;
        if (oldExt === undefined) {
            delete process.env.PATHEXT;
        } else {
            process.env.PATHEXT = oldExt;
        }
        fs.rmSync(dir, { recursive: true, force: true });
    }
});

test('workspaceRootFor prefers the owning folder, then the file dir', () => {
    const root = os.platform() === 'win32' ? 'C:\\ws' : '/ws';
    const other = os.platform() === 'win32' ? 'D:\\other' : '/other';
    folders = [{ uri: { fsPath: root } }];
    const inside = { fileName: path.join(root, 'a.orb'), uri: { scheme: 'file' } };
    assert.strictEqual(ext.workspaceRootFor(inside), root);
    const outside = { fileName: path.join(other, 'b.orb'), uri: { scheme: 'file' } };
    assert.strictEqual(ext.workspaceRootFor(outside), path.dirname(outside.fileName));
    folders = [];
    assert.strictEqual(ext.workspaceRootFor(outside), path.dirname(outside.fileName));
});

test('completions: import strings list only real std modules', () => {
    const out = complete.buildCompletions(vscodeStub, 'import "std/');
    assert.strictEqual(out.length, 14);
    const labels = out.map(i => i.label);
    assert.ok(labels.includes('std/string/string.orb'));
    assert.ok(!labels.includes('std/sys/net/socket.orb'));
    assert.ok(!labels.includes('std/core/result.orb'));
});

test('completions: member contexts and top-level exclusions', () => {
    const req = complete.buildCompletions(vscodeStub, 'val x = req.').map(i => i.label);
    assert.deepStrictEqual(req, ['param', 'query', 'body', 'header', 'bearer_token', 'has_role', 'role', 'file']);
    const sys = complete.buildCompletions(vscodeStub, 'system.').map(i => i.label);
    assert.strictEqual(sys.length, 8);
    const model = complete.buildCompletions(vscodeStub, 'Note.').map(i => i.label);
    assert.deepStrictEqual(model, ['all', 'where', 'find', 'create', 'delete']);
    // Capitalised container spellings are types, not models.
    const list = complete.buildCompletions(vscodeStub, 'List.').map(i => i.label);
    assert.ok(!list.includes('all'));
    const route = complete.buildCompletions(vscodeStub, 'route G').map(i => i.label);
    assert.ok(route.includes('GET'));
    const top = complete.buildCompletions(vscodeStub, '').map(i => i.label);
    assert.ok(!top.includes('loop'));
    assert.ok(!top.includes('with'));
    assert.ok(!top.includes('null'));
    assert.ok(!top.includes('Int'));
    assert.ok(top.includes('List'));
});

test('completion lists stay in sync with their exported sources', () => {
    assert.strictEqual(complete.STD_MODULES.length, 14);
    assert.strictEqual(complete.REQ_MEMBERS.length, 8);
    assert.strictEqual(complete.SYSTEM_MEMBERS.length, 8);
    assert.ok(!complete.KEYWORDS.includes('loop'));
    assert.ok(!complete.KEYWORDS.includes('then'));
});

test('file-icon suggestion fires once and never on its own theme', () => {
    assert.strictEqual(ext.shouldSuggestFileIcons(undefined, false), true);
    assert.strictEqual(ext.shouldSuggestFileIcons('seti', false), true);
    assert.strictEqual(ext.shouldSuggestFileIcons('orbit-icons', false), false);
    assert.strictEqual(ext.shouldSuggestFileIcons(undefined, true), false);
    assert.strictEqual(ext.shouldSuggestFileIcons('seti', true), false);
});

test('file-icon theme maps orb and ships every icon it names', () => {
    const themePath = path.join(__dirname, '..', 'orbit-file-icons-theme.json');
    const theme = JSON.parse(fs.readFileSync(themePath, 'utf8'));
    assert.strictEqual(theme.fileExtensions.orb, '_orb');
    assert.ok(theme.iconDefinitions._orb);
    for (const key of Object.keys(theme.iconDefinitions)) {
        const rel = theme.iconDefinitions[key].iconPath;
        assert.ok(rel, key + ' has no iconPath');
        assert.ok(
            fs.existsSync(path.join(__dirname, '..', rel)),
            rel + ' is missing'
        );
    }
});

if (failures > 0) {
    console.log('\n' + failures + ' failing');
    process.exit(1);
}
console.log('\nall passing');