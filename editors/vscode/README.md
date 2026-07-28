# Orbit Programming Language

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Status](https://img.shields.io/badge/Status-0.1.0--rc.2-green.svg)](STATUS.md)
![Orbit Banner](banner.png)

The official Visual Studio Code extension for **Orbit** — a high-performance, statically typed systems programming language engineered for high-concurrency web services and APIs.



## Quickstart & Installation

### Option 1: Automated Script Installation

If you installed Orbit via the automated installer, the VS Code extension was registered automatically:

**Windows (PowerShell)**:
```powershell
powershell -ExecutionPolicy Bypass -File scripts/install.ps1
```

**Linux / macOS (Bash)**:
```bash
bash scripts/install.sh
```

### Option 2: Manual VSIX Installation

1. Build the extension package:
   ```bash
   cd editors/vscode
   vsce package
   ```
2. Install in VS Code:
   ```bash
   code --install-extension orbit-vscode-0.1.0.vsix
   ```

---

## Configuration Settings

This extension provides the following configurable settings:

| Setting | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `orbit.executablePath` | `string` | `""` | Custom path to the `orbit` or `orbit.exe` binary. If left empty, the extension automatically locates Orbit. |

---

## Syntax Highlighting Preview

```orbit
port 3000
cors "*"
database "sqlite://orbit.db"

kynx {
  rate_limit 1000 per_minute
}

model User {
  id: Int
  email: String
  role: String
}

@auth
route GET "/users" {
  val users = User.all()
  return users
}
```

---

## License

Distributed under the **MIT License**. See [LICENSE](../../LICENSE) for more information.
