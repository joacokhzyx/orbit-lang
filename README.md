# ⏣ Orbit Programming Language

Orbit is a compiled, closed-source, high-performance programming language designed for writing backend web services and API servers. It natively embeds the SQLite database engine, features recovery-first error semantics (`rescue`), and incorporates robust production-grade anti-reverse engineering protections.

---

## 🚀 Key Features

* **📦 Hardened Native Compilation**: Automatically strips debug info and symbols (`-s`) and optimizes control flow via LLVM `-O3`.
* **🔒 Reverse Engineering Protection**: Built-in runtime checks block debugger attachment on Windows (via `IsDebuggerPresent`) and Linux (via `ptrace`).
* **🗃️ Built-in Database Engine**: Compiles SQLite directly into your server executables.
* **🛡️ Recovery-First Semantics**: Advanced error recovery using `rescue` fallback expressions.
* **⚙️ Multi-Platform CI/CD**: Auto-compiles binaries and packs installers for Windows, Linux, and macOS.

---

## 🛠️ Official Installers

### Windows Setup Wizard (Inno Setup)
Windows builds are distributed as a single Setup Wizard (`orbit-windows-setup.exe`) built via Inno Setup:
* Installs the compiler to Local AppData (`%LOCALAPPDATA%\Orbit`).
* Configures file associations so `.orb` files automatically open/run using `orbit.exe`.
* Registers the official Orbit icon (`orbit.ico`) as the default system icon for `.orb` files.
* Automatically appends the Orbit binary path to the user's `PATH` registry environment key.

### Linux / macOS Shell Installer
For Unix-like systems, Orbit packages include a native `install.sh` script:
* Places the relocatable compiler and C-runtime headers in `~/.orbit`.
* Dynamically updates `.bashrc`, `.zshrc`, or `.profile` to register Orbit globally in your PATH.

---

## 📖 Documentation Catalog

Discover how to write, compile, and protect your Orbit applications:
* **[Introduction to Orbit](docs/INTRODUCTION.md)**: Architecture, features, and quickstart.
* **[Syntax Reference](docs/SYNTAX_GUIDE.md)**: Variables, routing keywords, and error recovery.
* **[Production Hardening & Anti-RE](docs/PRODUCTION_DEPLOYMENT.md)**: Compiler hardening flags and runtime anti-debugger techniques.
