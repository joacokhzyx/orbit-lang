// Orbit extension for VS Code.
//
// There is no language server. `orbit` has no `lsp` subcommand -- `orbit lsp`
// prints "Unknown command: lsp" and exits 2 -- so the previous version of this
// file started a client against a binary that could never answer, and every
// activation ended in an error notification. What is left here is the part the
// compiler can actually do: run `orbit check` and put the diagnostics it
// already prints where an editor can show them.

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFile } = require('child_process');
const { parseDiagnostics } = require('./diagnostics');

let diagnostics = null;
let statusItem = null;
let executablePath = null;
let warnedMissing = false;

function isWindows() {
    return os.platform() === 'win32';
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
    const configured = vscode.workspace.getConfiguration('orbit').get('executablePath');
    if (configured) {
        const explicit = firstExisting([configured]);
        if (explicit) {
            return explicit;
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
    const exts = isWindows()
        ? (process.env.PATHEXT || '.EXE;.CMD;.BAT').split(';')
        : [''];
    for (const dir of pathVar.split(isWindows() ? ';' : ':')) {
        if (!dir) {
            continue;
        }
        for (const ext of exts) {
            const candidate = path.join(dir, exeName + ext);
            try {
                if (fs.statSync(candidate).isFile()) {
                    return candidate;
                }
            } catch (_) { /* not here; keep looking */ }
        }
    }
    return null;
}

function setStatus() {
    if (!statusItem) {
        return;
    }
    if (executablePath) {
        statusItem.text = '$(check) orbit';
        statusItem.tooltip = 'Orbit: ' + executablePath;
        statusItem.command = 'orbit.checkActiveFile';
    } else {
        statusItem.text = '$(circle-slash) orbit not found';
        statusItem.tooltip =
            'No orbit binary on PATH. Set orbit.executablePath. ' +
            'Syntax highlighting still works.';
        statusItem.command = undefined;
    }
}

// `orbit check` writes nothing to stdout and diagnostics to stderr on
// failure, and "Checked <path>: no errors." to stdout with exit 0 on success
// (compiler/pipeline.orb). The text side of that lives in diagnostics.js;
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

function checkDocument(document) {
    return new Promise(resolve => {
        if (!executablePath) {
            resolve([]);
            return;
        }
        // ORBIT_CC has to be set for a program's own build; `check` emits no
        // C, so a C compiler is not needed here and we do not require one.
        execFile(
            executablePath,
            ['check', document.fileName],
            { cwd: workspaceRootFor(document), timeout: 30000, windowsHide: true },
            (err, stdout, stderr) => {
                if (err && err.code === 'ENOENT') {
                    executablePath = null;
                    setStatus();
                    resolve([]);
                    return;
                }
                const text = (stderr || '') + (stdout || '');
                if (!err) {
                    resolve([]);
                    return;
                }
                resolve(toVscodeDiagnostics(parseDiagnostics(text)));
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
            if (!rel.startsWith('..')) {
                return folder.uri.fsPath;
            }
        }
        return folders[0].uri.fsPath;
    }
    return path.dirname(document.fileName);
}

async function refresh(document) {
    if (!diagnostics || !document || document.languageId !== 'orbit') {
        return;
    }
    const found = await checkDocument(document);
    diagnostics.set(document.uri, found);
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
            const found = await checkDocument(editor.document);
            diagnostics.set(editor.document.uri, found);
            if (found.length === 0) {
                vscode.window.showInformationMessage(
                    'orbit check: no errors in ' + path.basename(editor.document.fileName) + '.'
                );
            } else {
                vscode.window.showWarningMessage(
                    'orbit check: ' + found.length + ' problem' + (found.length === 1 ? '' : 's') + '.'
                );
            }
        })
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('orbit.runActiveFile', () => {
            if (!executablePath) {
                vscode.window.showWarningMessage('Orbit compiler not found.');
                return;
            }
            const editor = vscode.window.activeTextEditor;
            if (!editor || editor.document.languageId !== 'orbit') {
                vscode.window.showInformationMessage('Open an Orbit file first.');
                return;
            }
            if (editor.document.isDirty) {
                editor.document.save();
            }
            // `run` builds first, and the build step needs a C compiler in
            // ORBIT_CC, so hand it a terminal where its output is visible.
            const terminal = vscode.window.createTerminal({
                name: 'orbit run',
                cwd: workspaceRootFor(editor.document),
            });
            terminal.show();
            terminal.sendText(
                'ORBIT_CC=' + (process.env.ORBIT_CC || 'cc') +
                ' "' + executablePath + '" run "' + editor.document.fileName + '"'
            );
        })
    );

    context.subscriptions.push(
        vscode.workspace.onDidSaveTextDocument(doc => {
            if (doc.languageId === 'orbit') {
                refresh(doc);
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
                executablePath = findOrbitExecutable();
                setStatus();
                refreshAllOpen();
            }
        })
    );

    if (executablePath) {
        refreshAllOpen();
    }
}

function deactivate() {
    if (diagnostics) {
        diagnostics.dispose();
        diagnostics = null;
    }
}

module.exports = {
    activate,
    deactivate,
};
