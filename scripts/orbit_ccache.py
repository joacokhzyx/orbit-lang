#!/usr/bin/env python3
"""Content-addressed cache for the bootstrap's C compilations.

The self-host gates recompile the same multi-megabyte C translation unit over
and over. Measured on a 2-core runner with gcc 13.3, compiling the 3.9 MB
canonical unit costs 23.8 s with `-Wall` and 3.7 s with `-w`, and
`verify_seed.py` performs 7 such compilations per run while the stress gate runs
it 8 times in a row: 61 compilations of essentially the same input.

A cache keyed on the exact inputs makes the repeat cost a file copy. The key
covers everything that can change the output:

    cc identity (command + --version)  |  every flag except -o and its value
    |  every input file's size + SHA-256  |  the destination basename

Two details matter for honesty here:

- the destination BASENAME is in the key, not the destination directory. The
  linkers embed the output name (as a PDB path on PE targets) and the
  compilers embed the source path, so two builds that differ only by output
  name are genuinely different artifacts. Keying on the directory instead
  would make every run a miss, because the gates use a fresh temporary work
  directory per invocation.
- a hit is a real hit: same compiler, same version, same flags, same bytes
  in. Nothing is keyed on mtime or on anything a stale cache could fake.

What a cache hit does NOT do is turn a determinism check into a tautology.
`verify_seed.py` compares the emitted C of every stage against the canonical C;
that check reads files the compiler wrote and is unaffected. The binary
fixed-point comparison is documented as toolchain-specific and informational
for gcc/clang; callers must report cache hits for it rather than claim a pass
(see `hit_is_reuse`).
"""

import hashlib
import os
import shutil
import subprocess
import sys

_CHUNK = 1 << 20


def cache_root() -> str:
    """Directory holding cached artifacts."""
    override = os.environ.get("ORBIT_CCACHE_DIR", "").strip()
    if override:
        return os.path.abspath(override)
    base = os.environ.get("XDG_CACHE_HOME", "").strip() or os.path.join(
        os.path.expanduser("~"), ".cache")
    return os.path.join(base, "orbit", "cc")


def enabled() -> bool:
    """False when ORBIT_CCACHE=0, or when no cache directory is usable."""
    if os.environ.get("ORBIT_CCACHE", "1").strip().lower() in ("0", "false", "no"):
        return False
    try:
        os.makedirs(cache_root(), exist_ok=True)
        probe = os.path.join(cache_root(), ".writable")
        with open(probe, "w") as f:
            f.write("")
        os.remove(probe)
        return True
    except OSError:
        return False


def _cc_identity(cc_cmd) -> str:
    exe = cc_cmd[0]
    try:
        proc = subprocess.run([exe, "--version"], capture_output=True, text=True,
                              errors="replace", timeout=60)
        banner = (proc.stdout or "").strip().splitlines()
        return (exe + "|" + (banner[0] if banner else "unknown")).strip()
    except Exception:
        return exe


def _file_digest(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(_CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def compute_key(cc_cmd, argv, sources) -> str:
    """SHA-256 over every input that can affect the compiled artifact.

    Path arguments are reduced to their BASENAME before hashing. The gates use
    a fresh temporary work directory per invocation, so hashing absolute paths
    would make every run a miss; the basenames are already the contract
    (the compilers embed the source name and the linkers the output name, and
    the gates deliberately keep both constant across stages).
    """
    h = hashlib.sha256()
    h.update(_cc_identity(cc_cmd).encode("utf-8", "replace"))
    h.update(b"\0argv\0")
    for tok in argv:
        if os.path.isabs(tok) or os.sep in tok:
            tok = os.path.basename(tok)
        h.update(tok.encode("utf-8", "replace"))
        h.update(b"\0")
    h.update(b"\0sources\0")
    for src in sorted(sources):
        h.update(os.path.basename(src).encode("utf-8", "replace"))
        h.update(b"\0")
        h.update(_file_digest(src).encode("ascii"))
        h.update(b"\0")
    return h.hexdigest()


def _out_target(argv):
    for i, tok in enumerate(argv):
        if tok == "-o" and i + 1 < len(argv):
            return argv[i + 1]
    return None


# --------------------------------------------------------------------------
# Windows binary branding: every .exe linked on Windows carries Orbit's own
# version resource + mark. Fixed metadata, never user input: there is no
# syntax for it, so a .orb file cannot fake the brand.
# --------------------------------------------------------------------------

_ORBIT_COMPANY = "orbit-lang"
_ORBIT_PRODUCT = "Orbit"
_ORBIT_COPYRIGHT = "MIT"


def _orbit_version():
    """The compiler's own version string, read from its source of truth.

    pipeline.orb owns fn orbitVersion; parse it rather than duplicating the
    literal here. None when unparseable: callers skip stamping rather than
    stamping a wrong version.
    """
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        path = os.path.join(os.path.dirname(here), "compiler", "host", "pipeline.orb")
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    import re
    m = re.search(r'fn orbitVersion\(\) -> string \{\s*return "([^"]+)"', text)
    return m.group(1) if m else None


def _version_nums(version):
    """'0.1.0-rc.2' -> '0,1,0,2': leading digits of the first three dot parts,
    trailing digits of the last part. The -rc tail drops out of the numeric
    fields; the full string stays in the text fields."""
    import re
    parts = version.split(".")
    nums = []
    for p in parts[:3]:
        m = re.match(r"\d+", p)
        nums.append(m.group(0) if m else "0")
    last = parts[3] if len(parts) > 3 else (parts[-1] if parts else "")
    m = re.search(r"(\d+)$", last)
    nums.append(m.group(1) if m else "0")
    while len(nums) < 4:
        nums.append("0")
    return ",".join(nums[:4])


def _orbit_rc_text(exe_base, description, version, icon_path):
    nums = _version_nums(version)
    lines = [
        "1 VERSIONINFO",
        "FILEVERSION " + nums,
        "PRODUCTVERSION " + nums,
        "FILEFLAGSMASK 0x3fL",
        "FILEFLAGS 0x0L",
        "FILEOS 0x40004L",
        "FILETYPE 0x1L",
        "FILESUBTYPE 0x0L",
        "BEGIN",
        '    BLOCK "StringFileInfo"',
        "    BEGIN",
        '        BLOCK "040904b0"',
        "        BEGIN",
        '            VALUE "CompanyName", "%s"' % _ORBIT_COMPANY,
        '            VALUE "FileDescription", "%s"' % description,
        '            VALUE "FileVersion", "%s"' % version,
        '            VALUE "InternalName", "%s"' % exe_base,
        '            VALUE "LegalCopyright", "%s"' % _ORBIT_COPYRIGHT,
        '            VALUE "OriginalFilename", "%s"' % exe_base,
        '            VALUE "ProductName", "%s"' % _ORBIT_PRODUCT,
        '            VALUE "ProductVersion", "%s"' % version,
        "        END",
        "    END",
        '    BLOCK "VarFileInfo"',
        "    BEGIN",
        '        VALUE "Translation", 0x409, 1200',
        "    END",
        "END",
    ]
    if icon_path:
        lines.append('IDI_ICON1 ICON "%s"' % icon_path.replace("\\", "/"))
    return "\n".join(lines) + "\n"


def _which_resource_compiler():
    for name in ("windres", "llvm-rc"):
        if shutil.which(name):
            return name
    return None


def windows_stamp(argv, sources, workdir, description, log=None):
    """Append Orbit branding to a cc link: (argv, sources) -> (argv, sources).

    No-op off Windows, when the version is unparseable, or when neither
    windres nor llvm-rc exists (logged; the build proceeds unstamped rather
    than failing for branding alone). The .res joins both argv and sources
    so the content cache keys on it.
    """
    if os.name != "nt":
        return argv, sources
    target = _out_target(argv)
    if target is None:
        return argv, sources
    version = _orbit_version()
    if not version:
        if log:
            log("orbit metadata: cannot parse orbitVersion; shipping unstamped")
        return argv, sources
    rc_tool = _which_resource_compiler()
    if rc_tool is None:
        if log:
            log("orbit metadata: no resource compiler (windres/llvm-rc); shipping unstamped")
        return argv, sources
    exe_base = os.path.basename(target)
    stem = os.path.splitext(exe_base)[0] or "orbit"
    try:
        os.makedirs(workdir, exist_ok=True)
    except OSError:
        return argv, sources
    here = os.path.dirname(os.path.abspath(__file__))
    icon_cand = os.path.join(os.path.dirname(here), "assets", "orbit.ico")
    icon = icon_cand if os.path.isfile(icon_cand) else ""
    rc_path = os.path.join(workdir, stem + ".orbit.rc")
    res_path = os.path.join(workdir, stem + ".orbit.res")
    try:
        with open(rc_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(_orbit_rc_text(exe_base, description, version, icon))
    except OSError:
        return argv, sources
    try:
        if rc_tool == "windres":
            subprocess.run([rc_tool, rc_path, "-O", "coff", "-o", res_path],
                           capture_output=True, timeout=120)
        else:
            subprocess.run([rc_tool, "/FO", res_path, rc_path],
                           capture_output=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        pass
    if not os.path.isfile(res_path):
        if log:
            log("orbit metadata: %s failed; shipping unstamped" % rc_tool)
        return argv, sources
    return argv + [res_path], sources + [res_path]


def _entry(key: str) -> str:
    return os.path.join(cache_root(), key[:2], key)


def _load(key: str):
    """Return (artifact_path, mode) for a completed entry, else (None, None)."""
    entry = _entry(key)
    meta_path = entry + ".meta"
    art_path = entry + ".art"
    if not (os.path.isfile(meta_path) and os.path.isfile(art_path)):
        return None, None
    try:
        with open(meta_path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return None, None
    if not lines or lines[0] != "complete":
        # A torn entry from an interrupted run: never trust it.
        return None, None
    mode = 0o755
    if len(lines) > 1:
        try:
            mode = int(lines[1], 8)
        except ValueError:
            mode = 0o755
    return art_path, mode


def _store(key: str, artifact: str) -> None:
    entry = _entry(key)
    os.makedirs(os.path.dirname(entry), exist_ok=True)
    art_path = entry + ".art"
    tmp_art = art_path + ".tmp%d" % os.getpid()
    shutil.copyfile(artifact, tmp_art)
    os.replace(tmp_art, art_path)
    try:
        mode = os.stat(artifact).st_mode & 0o7777
    except OSError:
        mode = 0o755
    # The meta file is written last and carries the completion marker, so a
    # crash mid-store can only ever leave an entry that reads as a miss.
    tmp_meta = entry + ".meta.tmp%d" % os.getpid()
    with open(tmp_meta, "w", encoding="utf-8", newline="\n") as f:
        f.write("complete\n%o\n" % mode)
    os.replace(tmp_meta, entry + ".meta")


def compile_cached(cc_cmd, argv, sources, log=None):
    """Run `argv` (a full cc invocation ending in -o TARGET), cached by content.

    Returns (target_path, hit). On a hit the cached artifact is copied to the
    requested target; on a miss `argv` runs and its output is stored.
    """
    target = _out_target(argv)
    if target is None or not enabled():
        subprocess.run(argv, check=True)
        return target, False

    try:
        key = compute_key(cc_cmd, argv, sources)
    except OSError as e:
        if log:
            log("cc cache: cannot key %s (%s); compiling directly" % (target, e))
        subprocess.run(argv, check=True)
        return target, False

    art_path, mode = _load(key)
    if art_path is not None:
        try:
            dest_dir = os.path.dirname(os.path.abspath(target))
            if dest_dir:
                os.makedirs(dest_dir, exist_ok=True)
            shutil.copyfile(art_path, target)
            os.chmod(target, mode)
            if log:
                log("cc cache: reused %s" % os.path.basename(target))
            return target, True
        except OSError as e:
            if log:
                log("cc cache: cannot restore %s (%s); recompiling" % (target, e))

    subprocess.run(argv, check=True)
    if os.path.isfile(target):
        try:
            _store(key, target)
        except OSError as e:
            if log:
                log("cc cache: cannot store %s (%s)" % (os.path.basename(target), e))
    return target, False


def main(argv=None) -> int:
    """Report the cache location and size (diagnostic only)."""
    root = cache_root()
    total, entries = 0, 0
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if name.endswith(".art"):
                entries += 1
                try:
                    total += os.path.getsize(os.path.join(dirpath, name))
                except OSError:
                    pass
    print("cc cache: %s" % root)
    print("cc cache: %d entries, %.1f MB, enabled=%s" % (entries, total / 1e6, enabled()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
