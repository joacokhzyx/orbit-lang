#!/usr/bin/env bash
# Orbit Programming Language Automated Linux & macOS Installer
# Installs the self-hosted Orbit compiler (Zig-free bootstrap), configures PATH,
# and registers the VS Code extension.

set -e

echo "================================================================"
echo " Orbit Programming Language - Automated Linux/macOS Setup"
echo "================================================================"

INSTALL_DIR="$HOME/.orbit/bin"
mkdir -p "$INSTALL_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

SOURCE_EXE=""

# 1a. Prefer a pre-built fixed-point compiler shipped with a release.
FIXED_POINT="$ROOT_DIR/dist/orbit-linux-x86_64"
if [ -f "$FIXED_POINT" ]; then
    SOURCE_EXE="$FIXED_POINT"
    echo "[+] Selected released fixed-point compiler: $SOURCE_EXE"
fi

# 1b. Zig-free self-hosted bootstrap from the committed canonical C.
#     Root of trust: compiler/selfhost/stage3.exe.c + any C compiler.
if [ -z "$SOURCE_EXE" ]; then
    if [ ! -f "$ROOT_DIR/compiler/selfhost/stage3.exe.c" ]; then
        echo "[ERROR] Canonical compiler C source not found at compiler/selfhost/stage3.exe.c." >&2
        exit 1
    fi
    PY="$(command -v python3 || command -v python)"
    if [ -z "$PY" ]; then
        echo "[ERROR] Python is required to run the Zig-free bootstrap (scripts/build_selfhost.py)." >&2
        exit 1
    fi
    echo "[*] Building self-hosted fixed-point compiler (no Zig involved)..."
    BUILD_ARGS=("$ROOT_DIR/scripts/build_selfhost.py" --out "$INSTALL_DIR/orbit")
    if [ -n "$ORBIT_CC" ]; then
        BUILD_ARGS+=(--cc "$ORBIT_CC")
    fi
    "$PY" "${BUILD_ARGS[@]}"
    SOURCE_EXE="$INSTALL_DIR/orbit"
    echo "[+] Selected self-hosted fixed-point compiler: $SOURCE_EXE"
fi

if [ "$SOURCE_EXE" != "$INSTALL_DIR/orbit" ]; then
    cp "$SOURCE_EXE" "$INSTALL_DIR/orbit"
    chmod +x "$INSTALL_DIR/orbit"
fi
echo "[+] Installed Orbit binary to $INSTALL_DIR/orbit"

# Update PATH in shell config files
PATH_LINE='export PATH="$HOME/.orbit/bin:$PATH"'

if [ -f "$HOME/.bashrc" ] && ! grep -q "$INSTALL_DIR" "$HOME/.bashrc"; then
    echo "$PATH_LINE" >> "$HOME/.bashrc"
    echo "[+] Added $INSTALL_DIR to ~/.bashrc"
fi

if [ -f "$HOME/.zshrc" ] && ! grep -q "$INSTALL_DIR" "$HOME/.zshrc"; then
    echo "$PATH_LINE" >> "$HOME/.zshrc"
    echo "[+] Added $INSTALL_DIR to ~/.zshrc"
fi

# Register VS Code Extension
VSCODE_EXT_DIR="$HOME/.vscode/extensions/orbit-lang"
if [ -d "$ROOT_DIR/editors/vscode" ]; then
    mkdir -p "$VSCODE_EXT_DIR"
    cp -r "$ROOT_DIR/editors/vscode/"* "$VSCODE_EXT_DIR/"
    echo "[+] Registered Orbit VS Code Extension & LSP in $VSCODE_EXT_DIR"
fi

echo ""
echo "================================================================"
echo " [SUCCESS] Orbit setup completed successfully!"
echo " Restart your terminal or run: source ~/.bashrc (or ~/.zshrc)"
echo " Then verify installation with: orbit --help"
echo "================================================================"
