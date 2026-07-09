# Production Deployment & Anti-Reverse Engineering

Orbit is optimized for production-grade, closed-source deployments. It includes native compile-time and runtime mechanisms to protect proprietary source code.

## Binary Hardening and Symbol Stripping

Orbit binaries compiled via `orbit build` automatically undergo:
- **Symbol Stripping (`-s` flag)**: Removes all debug tables, trace entries, and symbol names.
- **LLVM O3 Optimizations**: Scrambles control flow, inlines critical calls, and optimizes registry mapping, making decompilation and reverse-engineering extremely difficult.

## Anti-Debugging Measures

Every compiled Orbit executable automatically includes runtime anti-debugging checks:
* **Windows**: Invokes `IsDebuggerPresent()` at startup and exits immediately if a debugger is attached.
* **Linux/macOS**: Employs `ptrace(PTRACE_TRACEME, ...)` check to prevent debuggers from attaching.

## CI/CD Releases

Orbit supports multi-platform compilation via GitHub Actions (see `.github/workflows/release.yml`):
* **Windows**: Generates a setup wizard installer (`orbit-windows-setup.exe`) using Inno Setup.
* **Linux/macOS**: Packages binaries into a distribution archive with a native shell script installer.
