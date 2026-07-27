#!/usr/bin/env bash
# Orbit Programming Language Automated Linux & macOS Installer
# Builds and installs Orbit self-hosted or bootstrap compiler binary, configures PATH, and registers VS Code Extension.

set -e

echo "================================================================"
echo " Orbit Programming Language - Automated Linux/macOS Setup"
echo "================================================================"

INSTALL_DIR="$HOME/.orbit/bin"
mkdir -p "$INSTALL_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

USE_SELFHOST=1

for arg in "$@"; do
  case $arg in
    --bootstrap)
      USE_SELFHOST=0
      shift
      ;;
    --selfhost)
      USE_SELFHOST=1
      shift
      ;;
  esac
done

echo "[*] Building Orbit bootstrap compiler with Zig..."
zig build -Doptimize=ReleaseFast

SOURCE_EXE="$ROOT_DIR/zig-out/bin/orbit"
if [ ! -f "$SOURCE_EXE" ]; then
    SOURCE_EXE="$ROOT_DIR/orbit"
fi

if [ "$USE_SELFHOST" -eq 1 ]; then
    echo "[*] Building Self-Hosted Orbit Compiler (Stage 1 / Stage 2)..."
    if "$SOURCE_EXE" bootstrap; then
        SELFHOST_STAGE1="$ROOT_DIR/compiler/selfhost/stage1.exe"
        if [ -f "$SELFHOST_STAGE1" ]; then
            SOURCE_EXE="$SELFHOST_STAGE1"
            echo "[+] Selected Self-Hosted Orbit Compiler: $SOURCE_EXE"
        fi
    else
        echo "[!] Self-hosted build fallback to bootstrap compiler."
    fi
fi

cp "$SOURCE_EXE" "$INSTALL_DIR/orbit"
chmod +x "$INSTALL_DIR/orbit"
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
