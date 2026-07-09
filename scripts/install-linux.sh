#!/usr/bin/env bash

# Orbit Programming Language installer script for Linux / macOS

set -euo pipefail

# Style definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0;7m' # No Color
BOLD='\033[1m'

echo -e "${BLUE}==================================================${NC}"
echo -e "${BOLD}         ⏣ ORBIT LANGUAGE INSTALLER (LINUX)      ${NC}"
echo -e "${BLUE}==================================================${NC}"

# Define installer parameters
INSTALL_DIR="${HOME}/.orbit"
BIN_DIR="${INSTALL_DIR}/bin"
RUNTIME_DIR="${INSTALL_DIR}/src/runtime"
SQLITE_DIR="${INSTALL_DIR}/src/lib/sqlite"

# Create directories
echo -e "Creating directories in ${INSTALL_DIR}..."
mkdir -p "${BIN_DIR}"
mkdir -p "${RUNTIME_DIR}"
mkdir -p "${SQLITE_DIR}"

# Locate source directory
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Copy files
if [ -f "${SRC_DIR}/zig-out/bin/orbit" ]; then
    echo -e "Copying compiler binary..."
    cp "${SRC_DIR}/zig-out/bin/orbit" "${BIN_DIR}/orbit"
    chmod +x "${BIN_DIR}/orbit"
else
    echo -e "${RED}Error: orbit compiler binary not found in zig-out/bin!${NC}"
    echo -e "Make sure to run 'zig build' first."
    exit 1
fi

if [ -d "${SRC_DIR}/src/runtime" ]; then
    echo -e "Copying C runtime headers and source files..."
    cp -r "${SRC_DIR}/src/runtime/"* "${RUNTIME_DIR}/"
else
    echo -e "${RED}Error: src/runtime directory not found!${NC}"
    exit 1
fi

if [ -d "${SRC_DIR}/src/lib/sqlite" ]; then
    echo -e "Copying SQLite source files..."
    cp -r "${SRC_DIR}/src/lib/sqlite/"* "${SQLITE_DIR}/"
else
    echo -e "${RED}Error: src/lib/sqlite directory not found!${NC}"
    exit 1
fi

# Add Orbit to shell configuration files
SHELL_PROFILES=("${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile")
PATH_ENTRY="export PATH=\"\$PATH:${BIN_DIR}\""

echo -e "Updating shell PATH environment variable..."
UPDATED=false

for PROFILE in "${SHELL_PROFILES[@]}"; do
    if [ -f "${PROFILE}" ]; then
        if ! grep -q "${BIN_DIR}" "${PROFILE}"; then
            echo -e "\n# Orbit Language PATH configuration" >> "${PROFILE}"
            echo "${PATH_ENTRY}" >> "${PROFILE}"
            echo -e "  Added PATH entry to ${PROFILE}"
            UPDATED=true
        else
            echo -e "  PATH entry already exists in ${PROFILE}"
        fi
    fi
done

echo -e "${BLUE}==================================================${NC}"
echo -e "${GREEN} ⏣ Orbit v0.1.0-rc.1 installed successfully!${NC}"
echo -e "${BLUE}==================================================${NC}"
echo -e "Installation path: ${INSTALL_DIR}"
echo -e ""
if [ "${UPDATED}" = true ]; then
    echo -e "Please restart your terminal session or run:"
    echo -e "    source ~/.bashrc  (or ~/.zshrc depending on your shell)"
else
    echo -e "You can now run: orbit --help"
fi
echo -e "=================================================="
