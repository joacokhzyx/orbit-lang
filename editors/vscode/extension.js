const vscode = require('vscode');
const { LanguageClient, TransportKind } = require('vscode-languageclient/node');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execSync } = require('child_process');

let client;

function findOrbitExecutable() {
    // 1. Check workspace settings
    const config = vscode.workspace.getConfiguration('orbit');
    const userPath = config.get('executablePath');
    if (userPath && fs.existsSync(userPath)) {
        return userPath;
    }

    // 2. Check PATH environment variable
    try {
        const cmd = os.platform() === 'win32' ? 'where orbit' : 'which orbit';
        const sysPath = execSync(cmd, { encoding: 'utf8' }).trim().split('\r\n')[0].split('\n')[0];
        if (sysPath && fs.existsSync(sysPath)) {
            return sysPath;
        }
    } catch (_) {}

    // 3. Check standard user home directory (~/.orbit/bin/orbit)
    const homeDir = os.homedir();
    const homeExe = os.platform() === 'win32'
        ? path.join(homeDir, '.orbit', 'bin', 'orbit.exe')
        : path.join(homeDir, '.orbit', 'bin', 'orbit');
    if (fs.existsSync(homeExe)) {
        return homeExe;
    }

    // 4. Check active workspace root folder
    if (vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders.length > 0) {
        const rootPath = vscode.workspace.workspaceFolders[0].uri.fsPath;
        const localExe = os.platform() === 'win32'
            ? path.join(rootPath, 'orbit.exe')
            : path.join(rootPath, 'orbit');
        if (fs.existsSync(localExe)) {
            return localExe;
        }

        const buildExe = os.platform() === 'win32'
            ? path.join(rootPath, 'zig-out', 'bin', 'orbit.exe')
            : path.join(rootPath, 'zig-out', 'bin', 'orbit');
        if (fs.existsSync(buildExe)) {
            return buildExe;
        }
    }

    // Fallback to global command name
    return 'orbit';
}

function activate(context) {
    const orbitPath = findOrbitExecutable();

    const serverOptions = {
        command: orbitPath,
        args: ['lsp'],
        transport: TransportKind.stdio
    };

    const clientOptions = {
        documentSelector: [{ scheme: 'file', language: 'orbit' }],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.orb')
        }
    };

    client = new LanguageClient(
        'orbitLsp',
        'Orbit Language Server',
        serverOptions,
        clientOptions
    );

    client.start().catch(err => {
        vscode.window.showErrorMessage(`Orbit Language Server failed to start: ${err.message}`);
    });
}

function deactivate() {
    if (!client) {
        return undefined;
    }
    return client.stop();
}

module.exports = {
    activate,
    deactivate
};
