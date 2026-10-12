// Orbit extension for VS Code.
//
// There is no language server. `orbit` has no `lsp` subcommand -- `orbit lsp`
// prints "Unknown command: lsp" and exits 2 -- so the previous version of this
// file started a client against a binary that could never answer, and every
// activation ended in an error notification. What is left here is the part the
// compiler can actually do: run `orbit check` and `orbit fmt`, and put the
// diagnostics `check` already prints where an editor can show them.
// Completion is a static client-side list (complete.js), never a guess about
// types: a hover that needs sema would lie, so there is none.

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFile } = require('child_process');
const { parseDiagnostics } = require('./diagnostics');
const { registerCompletionProvider } = require('./complete');

let diagnostics = null;
let statusItem = null;
let channel = null;
let executablePath = null;
let runTerminal = null;
let lastProblems = null;
let warnedMissing = false;
let warnedBadConfig = false;

// Rapid Ctrl+S spawns overlapping `orbit check`s with no last-write-wins, so
// saves are debounced per file. 300ms covers a save storm, not a slow check.
const SAVE_DEBOUNCE_MS = 300;
const saveTimers = new Map();

function isWindows() {
    return os.platform() === 'win32';
}

function orbitConfig() {
    return vscode.workspace.getConfiguration('orbit');
}

function checkOnSave() {
    return orbitConfig().get('checkOnSave', true);
}

function maxProblems() {
    const n = orbitConfig().get('maxProblems', 100);
    return typeof n === 'number' && n > 0 ? Math.floor(n) : 100;
}

function firstExisting(candidates) {
    for (const candidate of candidates) {
        if (candidate && fs.existsSync(candidate)) {
            return candidate;
        }
    }
    return null;
}

// Resolution order, most explicit first. Returns null rather than the bare
// string "orbit" so a missing compiler is a state we can report instead of a
// spawn error we have to catch later.
function findOrbitExecutable() {
    const configured = orbitConfig().get('executablePath');
    if (configured) {
        const explicit = firstExisting([configured]);
        if (explicit) {
            return explicit;
        }
        // A typo in the setting used to fall through silently and let a PATH
        // binary shadow it. Say so once instead.
        if (!warnedBadConfig) {
            warnedBadConfig = true;
            vscode.window.showWarningMessage(
                'orbit.executablePath does not exist: ' + configured + '. ' +
                'Falling back to PATH search.'
            );
        }
    }

    const exeName = isWindows() ? 'orbit.exe' : 'orbit';
    const onPath = findOnPath(exeName);
    if (onPath) {
        return onPath;
    }

    const home = os.homedir();
    const fromHome = firstExisting([
        path.join(home, '.orbit', 'bin', exeName),
        path.join(home, '.orbit', exeName),
    ]);
    if (fromHome) {
        return fromHome;
    }

    const folders = vscode.workspace.workspaceFolders || [];
    for (const folder of folders) {
        const fromWorkspace = firstExisting([
            path.join(folder.uri.fsPath, exeName),
            path.join(folder.uri.fsPath, 'dist', exeName),
        ]);
        if (fromWorkspace) {
            return fromWorkspace;
        }
    }
    return null;
}

function findOnPath(exeName) {
    const pathVar = process.env.PATH || '';
    const sep = isWindows() ? ';' : ':';
    // The exact name first: on Windows exeName is already `orbit.exe`, so
    // appending PATHEXT blindly looks for `orbit.exe.EXE` and never matches.
    const exts = isWindows()
        ? ['', ...new Set(
            (process.env.PATHEXT || '.EXE;.CMD;.BAT;.COM').split(';')
                .map(e => e.trim())
                .filter(e => e && e.toUpperCase() !== '.EXE')
                .map(e => e.startsWith('.') ? e : '.' + e)
        )]
        : [''];
    for (const dir of pathVar.split(sep)) {
        if (!dir) {
            continue;
        }
        for (const ext of exts) {
            // Skip re-appending an extension the name already carries.
            if (ext && exeName.toLowerCase().endsWith(ext.toLowerCase())) {
                continue;
            }
            const candidate = path.join(dir, exeName + ext);
            try {
                if (fs.statSync(candidate).isFile()) {
                    return candidate;
                }
            } catch (_) { /* not here; keep looking */ }
        }
        // Exact name on Windows (plain orbit.exe on PATH).
        if (isWindows()) {
            try {
                const exact = path.join(dir, exeName);
                if (fs.statSync(exact).isFile()) {
                    return exact;
                }
            } catch (_) { /* not here; keep looking */ }
        }
    }
    return null;
}

function log(line) {
    if (channel) {
        channel.appendLine(line);
    }
}

function setStatus() {
    if (!statusItem) {
        return;
    }
    if (!executablePath) {
        statusItem.text = '$(circle-slash) orbit not found';
        statusItem.tooltip =
            'No orbit binary on PATH. Set orbit.executablePath. ' +
            'Syntax highlighting still works.';
        statusItem.command = undefined;
        return;
    }
    statusItem.command = 'orbit.checkActiveFile';
    if (lastProblems === null) {
        statusItem.text = '$(check) orbit';
        statusItem.tooltip = 'Orbit: ' + executablePath;
    } else if (lastProblems === 0) {
        statusItem.text = '$(check) orbit';
        statusItem.tooltip = 'Orbit: no errors (' + executablePath + ')';
    } else {
        statusItem.text = '$(error) orbit: ' + lastProblems;
        statusItem.tooltip =
            'Orbit: ' + lastProblems + ' problem' +
            (lastProblems === 1 ? '' : 's') + ' (' + executablePath + ')';
    }
}

function setChecking() {
    if (statusItem && executablePath) {
        statusItem.text = '$(sync~spin) orbit';
        statusItem.tooltip = 'Orbit: checking…';
    }
}

// `orbit check` writes nothing to stdout and diagnostics to stderr on
// failure, and "Checked <path>: no errors." to stdout with exit 0 on success
// (compiler/main.orb runCheck). The text side of that lives in diagnostics.js;
// this turns the parsed records into editor ranges.
function toVscodeDiagnostics(records) {
    return records.map(record => {
        const start = record.line === null
            ? new vscode.Position(0, 0)
            : new vscode.Position(record.line, record.column || 0);
        const end = record.line === null
            ? start
            : new vscode.Position(record.line, (record.column || 0) + 1);
        const diagnostic = new vscode.Diagnostic(
            new vscode.Range(start, end),
            record.message,
            vscode.DiagnosticSeverity.Error
        );
        diagnostic.source = record.code;
        return diagnostic;
    });
}

function isUntitled(document) {
    return document.isUntitled || document.uri.scheme === 'untitled';
}

// Usage errors, unreadable inputs and unknown-command text match no diagnostic
// pattern; without this they would resolve to [] and read as "no errors".
function isSkippedCheck(text) {
    return /(^|\n)(Usage:|orbit check: could not read input file|Unknown (command|option):)/.test(text);
}

function checkDocument(document) {
    return new Promise(resolve => {
        if (!executablePath || isUntitled(document)) {
            resolve({ found: [], skipped: isUntitled(document), raw: '' });
            return;
        }
        // ORBIT_CC has to be set for a program's own build; `check` emits no
        // C, so a C compiler is not needed here and we do not require one.
        // --quiet drops the success chatter; errors always print.
        execFile(
            executablePath,
            ['check', document.fileName, '--quiet'],
            { cwd: workspaceRootFor(document), timeout: 30000, windowsHide: true },
            (err, stdout, stderr) => {
                if (err && err.code === 'ENOENT') {
                    executablePath = null;
                    setStatus();
                    resolve({ found: [], skipped: true, raw: 'orbit binary vanished (ENOENT).' });
                    return;
                }
                const text = (stderr || '') + (stdout || '');
                if (!err) {
                    resolve({ found: [], skipped: false, raw: text });
                    return;
                }
                if (isSkippedCheck(text)) {
                    resolve({ found: [], skipped: true, raw: text.trim().split(/\r?\n/)[0] || 'orbit check did not run.' });
                    return;
                }
                resolve({ found: toVscodeDiagnostics(parseDiagnostics(text)), skipped: false, raw: text });
            }
        );
    });
}

// `orbit fmt <file>` rewrites in place and writes only on success
// (compiler/fmt.orb); exit 1 on parse error or unreadable input. Never pass
// --verbose here: single-file fmt treats it as a usage error (exit 2).
function formatDocument(document) {
    return new Promise(resolve => {
        if (!executablePath || isUntitled(document) || document.isDirty) {
            resolve({ ok: false, reason: 'save first' });
            return;
        }
        execFile(
            executablePath,
            ['fmt', document.fileName],
            { cwd: workspaceRootFor(document), timeout: 30000, windowsHide: true },
            (err, stdout, stderr) => {
                const text = ((stderr || '') + (stdout || '')).trim();
                if (!err) {
                    resolve({ ok: true, raw: text });
                    return;
                }
                resolve({ ok: false, reason: text.split(/\r?\n/)[0] || 'orbit fmt failed.' });
            }
        );
    });
}

// `std/...` imports resolve against the compiler binary's directory, its
// parent, then the working directory (compiler/resolver.orb). Running check
// from the workspace root is what makes a `std/` import resolve, so do that.
function workspaceRootFor(document) {
    const folders = vscode.workspace.workspaceFolders || [];
    if (folders.length) {
        for (const folder of folders) {
            const rel = path.relative(folder.uri.fsPath, document.fileName);
            // A different-drive file yields an absolute rel on Windows, which
            // starts with neither '..' nor the folder; it owns nothing.
            if (!rel.startsWith('..') && !path.isAbsolute(rel)) {
                return folder.uri.fsPath;
            }
        }
        // The file is outside every folder: its own directory resolves
        // bare-relative imports; only then fall back to the first folder.
        try {
            if (document.fileName && !isUntitled(document)) {
                return path.dirname(document.fileName);
            }
        } catch (_) { /* fall through */ }
        return folders[0].uri.fsPath;
    }
    return path.dirname(document.fileName);
}

// check/run/fmt all read from disk, so an untitled or dirty buffer would act
// on stale text. Offer the save; untitled save() opens the Save dialog.
async function ensureSaved(editor) {
    if (!editor.document.isDirty && !isUntitled(editor.document)) {
        return true;
    }
    if (isUntitled(editor.document)) {
        const pick = await vscode.window.showWarningMessage(
            'Save the file first; orbit reads from disk.',
            'Save As…'
        );
        if (pick !== 'Save As…') {
            return false;
        }
    }
    const saved = await editor.document.save();
    return saved && !isUntitled(editor.document);
}

async function refresh(document) {
    if (!diagnostics || !document || document.languageId !== 'orbit') {
        return;
    }
    setChecking();
    const { found, skipped, raw } = await checkDocument(document);
    const capped = found.slice(0, maxProblems());
    diagnostics.set(document.uri, capped);
    lastProblems = skipped ? lastProblems : capped.length;
    setStatus();
    if (skipped && raw) {
        log('$ orbit check ' + document.fileName);
        log(raw);
    }
}

function refreshDebounced(document) {
    const key = document.uri.toString();
    const pending = saveTimers.get(key);
    if (pending) {
        clearTimeout(pending);
    }
    saveTimers.set(key, setTimeout(() => {
        saveTimers.delete(key);
        refresh(document);
    }, SAVE_DEBOUNCE_MS));
}

async function refreshAllOpen() {
    if (!diagnostics) {
        return;
    }
    const editor = vscode.window.activeTextEditor;
    if (editor && editor.document.languageId === 'orbit') {
        await refresh(editor.document);
    }
}

function activate(context) {
    diagnostics = vscode.languages.createDiagnosticCollection('orbit');
    context.subscriptions.push(diagnostics);

    channel = vscode.window.createOutputChannel('Orbit');
    context.subscriptions.push(channel);

    executablePath = findOrbitExecutable();
    if (!executablePath) {
        if (!warnedMissing) {
            warnedMissing = true;
            vscode.window
                .showWarningMessage(
                    'Orbit compiler not found. Syntax highlighting works; ' +
                    'orbit check and orbit run stay disabled. Set ' +
                    'orbit.executablePath to point at the binary.'
                )
                .then(choice => {
                    if (choice === 'orbit.executablePath') {
                        vscode.commands.executeCommand(
                            'workbench.action.openSettings',
                            'orbit.executablePath'
                        );
                    }
                });
        }
    }

    statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
    statusItem.command = 'orbit.checkActiveFile';
    context.subscriptions.push(statusItem);
    setStatus();
    statusItem.show();

    registerCompletionProvider(vscode, context);

    context.subscriptions.push(
        vscode.languages.registerDocumentFormattingEditProvider('orbit', {
            async provideDocumentFormattingEdits(document) {
                if (!executablePath) {
                    return [];
                }
                // The provider must not mutate: save first so fmt reads what
                // the buffer shows, then return the formatted text as edits.
                if (document.isDirty) {
                    await document.save();
                }
                if (isUntitled(document)) {
                    return [];
                }
                const before = document.getText();
                const result = await formatDocument(document);
                if (!result.ok) {
                    vscode.window.showWarningMessage('orbit fmt: ' + result.reason);
                    return [];
                }
                let after = before;
                try {
                    after = fs.readFileSync(document.fileName, 'utf8');
                } catch (_) {
                    return [];
                }
                if (after === before) {
                    return [];
                }
                const lastLine = document.lineCount - 1;
                const range = new vscode.Range(
                    new vscode.Position(0, 0),
                    document.lineAt(lastLine).range.end
                );
                return [vscode.TextEdit.replace(range, after)];
            },
        })
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('orbit.checkActiveFile', async () => {
            if (!executablePath) {
                vscode.window.showWarningMessage('Orbit compiler not found.');
                return;
            }
            const editor = vscode.window.activeTextEditor;
            if (!editor || editor.document.languageId !== 'orbit') {
                vscode.window.showInformationMessage('Open an Orbit file first.');
                return;
            }
            // `check` reads from disk, so a dirty buffer would check stale
            // text. Save first; onDidSave refreshes again and converges.
            if (!(await ensureSaved(editor))) {
                return;
            }
            setChecking();
            const { found, skipped, raw } = await checkDocument(editor.document);
            const capped = found.slice(0, maxProblems());
            diagnostics.set(editor.document.uri, capped);
            lastProblems = skipped ? lastProblems : capped.length;
            setStatus();
            if (skipped) {
                log('$ orbit check ' + editor.document.fileName);
                log(raw);
                channel.show(true);
                vscode.window.showErrorMessage('orbit check did not run: ' + raw);
            } else if (capped.length === 0) {
                vscode.window.showInformationMessage(
                    'orbit check: no errors in ' + path.basename(editor.document.fileName) + '.'
                );
            } else {
                vscode.window.showWarningMessage(
                    'orbit check: ' + capped.length + ' problem' + (capped.length === 1 ? '' : 's') + '.'
                );
            }
        })
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('orbit.formatActiveFile', async () => {
            if (!executablePath) {
                vscode.window.showWarningMessage('Orbit compiler not found.');
                return;
            }
            const editor = vscode.window.activeTextEditor;
            if (!editor || editor.document.languageId !== 'orbit') {
                vscode.window.showInformationMessage('Open an Orbit file first.');
                return;
            }
            await vscode.commands.executeCommand('editor.action.formatDocument');
        })
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('orbit.runActiveFile', async () => {
            if (!executablePath) {
                vscode.window.showWarningMessage('Orbit compiler not found.');
                return;
            }
            const editor = vscode.window.activeTextEditor;
            if (!editor || editor.document.languageId !== 'orbit') {
                vscode.window.showInformationMessage('Open an Orbit file first.');
                return;
            }
            if (!(await ensureSaved(editor))) {
                return;
            }
            // One terminal, reused: creation used to spawn a dead terminal
            // per run. cwd is fixed at creation and cannot change on reuse.
            if (!runTerminal || runTerminal.exitStatus !== undefined) {
                runTerminal = vscode.window.createTerminal({
                    name: 'orbit run',
                    cwd: workspaceRootFor(editor.document),
                });
            }
            log('$ orbit run ' + editor.document.fileName);
            runTerminal.show();
            // `run` builds first and needs a C compiler in ORBIT_CC. The
            // terminal inherits the extension host environment, so no
            // `ORBIT_CC=...` prefix: that prefix is sh syntax and breaks
            // cmd.exe/PowerShell. Quote paths; they may contain spaces.
            runTerminal.sendText(
                '"' + executablePath + '" run "' + editor.document.fileName + '"'
            );
        })
    );

    context.subscriptions.push(
        vscode.workspace.onDidSaveTextDocument(doc => {
            if (doc.languageId === 'orbit' && checkOnSave()) {
                refreshDebounced(doc);
            }
        })
    );

    context.subscriptions.push(
        vscode.workspace.onDidCloseTextDocument(doc => {
            if (diagnostics && doc.languageId === 'orbit') {
                diagnostics.delete(doc.uri);
            }
        })
    );

    context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration(event => {
            if (event.affectsConfiguration('orbit.executablePath')) {
                warnedBadConfig = false;
                executablePath = findOrbitExecutable();
                lastProblems = null;
                setStatus();
                refreshAllOpen();
            }
            if (event.affectsConfiguration('orbit.checkOnSave') && checkOnSave()) {
                refreshAllOpen();
            }
            if (event.affectsConfiguration('orbit.maxProblems')) {
                refreshAllOpen();
            }
        })
    );

    if (executablePath) {
        refreshAllOpen();
    }

    suggestFileIcons(context);
}

// Pure decision for the one-time file-icon suggestion: suggest only when the
// user is not already on the Orbit theme and has not been asked before.
// Kept pure so node test/extension_test.js covers it without the editor.
function shouldSuggestFileIcons(currentTheme, alreadyAsked) {
    if (alreadyAsked) {
        return false;
    }
    return currentTheme !== 'orbit-icons';
}

function suggestFileIcons(context) {
    try {
        if (!vscode.window || !vscode.window.showInformationMessage) {
            return;
        }
        const workbench = vscode.workspace.getConfiguration('workbench');
        const current = workbench ? workbench.get('iconTheme') : undefined;
        const asked = context.globalState
            ? context.globalState.get('orbit.iconsSuggested', false)
            : true;
        if (!shouldSuggestFileIcons(current, asked)) {
            return;
        }
        vscode.window
            .showInformationMessage(
                'Use Orbit file icons for .orb files?',
                'Use Orbit Icons',
                'Not now'
            )
            .then(choice => {
                try {
                    if (context.globalState) {
                        context.globalState.update('orbit.iconsSuggested', true);
                    }
                    if (choice === 'Use Orbit Icons' && workbench) {
                        workbench.update('iconTheme', 'orbit-icons', true);
                    }
                } catch (ignored) {
                    // A failed opt-in must never break activation.
                }
            });
    } catch (ignored) {
        // Suggesting is cosmetic; activation is not.
    }
}

function deactivate() {
    for (const timer of saveTimers.values()) {
        clearTimeout(timer);
    }
    saveTimers.clear();
    if (diagnostics) {
        diagnostics.dispose();
        diagnostics = null;
    }
}

module.exports = {
    activate,
    deactivate,
    // Exported for node test/extension_test.js (vscode is stubbed there).
    toVscodeDiagnostics,
    isSkippedCheck,
    isUntitled,
    findOnPath,
    workspaceRootFor,
    checkDocument,
    formatDocument,
    maxProblems,
    shouldSuggestFileIcons,
};
