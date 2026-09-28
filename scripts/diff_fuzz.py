#!/usr/bin/env python3
"""Differential fuzzer: Orbit's arithmetic against a reference implementation.

`scripts/fuzz_frontend.py` looks for crashes. A crash is loud: it prints a
message, returns a signal, and stops the run. The failures this repo actually
ships are the quiet ones -- a program that compiles clean, runs, and serves the
wrong number with no diagnostic anywhere. A crash-only fuzzer is structurally
unable to find those, because a wrong answer is not an event.

So this generates small programs whose value is computable by a reference
implementation, runs them, and compares. Python 3 is the reference because it is
what a reader would assume Orbit means, with the three places it does not mean
it corrected explicitly: integers are 32-bit two's complement, `/` and `%`
truncate toward zero rather than flooring, and an integer literal outside the
32-bit signed range is an error rather than a wrap.

The classes are the ones already known to be wrong, so the fuzzer proves itself
first and then widens:

    int-arith     + - * / % over signed operands, including 0 and the edges
                  around 2^31-1, 2^31 and 2^63
    int-literal   decimal, 0x, `_` separators, and the forms that do not exist
                  yet (0b, 0o, exponent), in a call position AND in a binding
    div-zero      `/ 0`, `% 0`, `INT_MIN / -1`, and the sign of the result
    string-escape the six escapes the language documents, `\\xHH`, the C
                  escapes it does NOT document, and the malformed ones
    float         round-tripping; floats are not implemented at all today, so
                  this class is reported on its own line and never mixed in

It is DETERMINISTIC. `--seed` fixes the corpus, generators run in a fixed
order, and the summary prints a SHA-256 of the case list, so two runs on two
machines can be shown to have run the same programs. A fuzzer whose corpus
moves cannot tell you whether a finding is new.

REPORT ONLY by default. It exits non-zero only with `--strict`, because a fuzzer
that fails the build on the day a finding appears is a fuzzer that gets turned
off on the day a finding appears. The findings are the deliverable. The count
is what `scripts/diff_fuzz_ratchet.py` holds one way (D9).

Usage:
    python scripts/diff_fuzz.py --compiler PATH [--seed N] [--iterations N]
                               [--batch N] [--cc CC] [--only CATEGORY]...
                               [--json PATH] [--strict] [--list]
"""

import argparse
import hashlib
import json
import os
import random
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

INT_MIN, INT_MAX = -(2 ** 31), 2 ** 31 - 1
SEED = 20240928
SENTINEL = "--df8<--"

CATEGORIES = ("int-arith", "int-literal", "int-literal-bind", "div-zero",
              "string-escape", "float")


# --------------------------------------------------------------------------
# The reference. Everything here is what a reader would assume Orbit means.
# --------------------------------------------------------------------------
def i32(x):
    """Wrap to signed 32-bit, which is what orbit_int is."""
    x &= 0xFFFFFFFF
    return x - 0x100000000 if x >= 0x80000000 else x


def c_div(a, b):
    """C99 integer division: truncate toward zero. Python's // floors."""
    q = abs(a) // abs(b)
    return i32(-q if (a < 0) != (b < 0) else q)


def c_mod(a, b):
    """C99 remainder: the sign follows the dividend, not the divisor."""
    return i32(a - c_div(a, b) * b)


# --------------------------------------------------------------------------
# Cases.
# --------------------------------------------------------------------------
class Case:
    """One program, and what a correct compiler does with it.

    kind is the expectation, and there are exactly five:
      value     the program's stdout must be exactly `expect`
      bytes     the program's stdout must be exactly `expect` (a bytes object),
                used where the output is not line-shaped
      either    `expect` OR a clean refusal. For a form the language does not
                have yet, where refusing is the correct answer today and the
                wrong answer tomorrow. A fuzzer that fails the day a missing
                feature is implemented is a fuzzer that gets switched off.
      reject    the program must NOT build, and must say why
      diagnose  the program must not die on a signal and must not print a
                number: a division by zero is either a compile-time or a
                runtime diagnostic, and a signal is neither
    """

    def __init__(self, category, source, kind, expect, note=""):
        self.category = category
        self.source = source        # the Orbit source of one `print(...)` call
        self.kind = kind
        self.expect = expect
        self.note = note

    def program(self):
        body = "".join("    %s\n" % line for line in self.source.splitlines())
        return "fn main() -> int {\n%s    return 0\n}\n" % body

    def label(self):
        return self.source


def literal_cases(rng, n_literals):
    """Integer literals: the forms that exist, and the ones that do not.

    Two judgement calls, both stated so they can be argued with:

    - `-2147483648` is a `reject` case in name only; the value IS representable
      (it is the minimum int), so the case expects the value. What must not
      happen is the bare `2147483648`, which is not a value the type has.
    - a form the language does not have (`0b`, `0o`, an exponent) is a GAP, not
      a wrong answer, so it gets the `either` expectation: refusing it is
      correct today, and the day someone implements it the case starts
      asserting the value instead. That is the useful direction for a fuzzer to
      fail in.
    """
    cases = []
    for n in (0, 1, 7, 9, 10, 42, 255, 256, 1000, 65535, INT_MAX, INT_MAX - 1):
        cases.append(Case("int-literal", "print(%d)" % n, "value", str(n)))
    cases.append(Case("int-literal", "print(-%d)" % -INT_MIN, "value", str(INT_MIN),
                      "the minimum int, written as a negation: representable"))
    for text, val in (("0x0", 0), ("0x10", 16), ("0xFF", 255), ("0x7FFFFFFF", INT_MAX),
                      ("1_000", 1000), ("1_000_000", 1000000), ("1_0_0", 100)):
        cases.append(Case("int-literal", "print(%s)" % text, "value", str(i32(val)),
                          "hex and the `_` separator"))
    # `_` works in a decimal literal and not in a hex one. A reader who has
    # learned one has every reason to expect the other.
    for text, want in (("0x1_000", "4096"), ("0x0_0", "0")):
        cases.append(Case("int-literal", "print(%s)" % text, "either", want,
                          "`_` separates digits in decimal (1_0_0 = 100) but "
                          "not in hex"))
    # out of range: a literal is a value the type does not have, so it has to
    # be refused. Folding it silently is how 2147483648 became -2147483648.
    for text in ("2147483648", "4294967296", "9223372036854775807",
                 "18446744073709551616", "99999999999999999999999",
                 "0xFFFFFFFF", "0x1_0000000"):
        cases.append(Case("int-literal", "print(%s)" % text, "reject", None,
                          "out of range for orbit_int (32-bit signed)"))
    # the forms that do not exist yet
    for text, want in (("0b1010", "10"), ("0o17", "15"), ("1e2", "100"),
                       ("2e3", "2000"), ("2.5e3", "2500"), ("2.5E3", "2500"),
                       ("2.5e-3", "0.0025")):
        cases.append(Case("int-literal", "print(%s)" % text, "either", want,
                          "form does not exist yet: refusing is correct, "
                          "answering something else is not"))
    cases.append(Case("int-literal", "print(007)", "value", "7", "leading zeros"))
    # seeded bulk: in-range decimals are uninteresting individually, but they
    # are what makes the corpus a corpus and not eight examples.
    for _ in range(n_literals):
        v = rng.randrange(INT_MIN, INT_MAX + 1)
        cases.append(Case("int-literal", "print(%d)" % v, "value", str(v)))
    return cases


def bind_cases():
    """The same literals, in a `val` binding instead of inside a call.

    This class exists because of a measured asymmetry, not a hunch. A literal
    that is REFUSED inside `print(...)` can be silently answered with a wrong
    number one token later:

        print(0b1010)            -> Parser error
        val x: int = 0b1010      -> 0
        print(0x1_000)           -> Parser error
        val x: int = 0x1_000     -> 1

    So a fuzzer that only ever puts a literal in a call position measures half
    the behaviour of a literal. Refusing is still acceptable -- these forms do
    not exist yet -- so the expectation is `either`: a clean refusal passes, and
    any number at all has to be the right one.
    """
    forms = [
        ("0b1010", "10"), ("0b0", "0"), ("0o17", "15"), ("0o777", "511"),
        ("1e2", "100"), ("2e3", "2000"), ("0x1_000", "4096"), ("0x0_0", "0"),
        # controls: these already work and must keep working
        ("0x10", "16"), ("1_0_0", "100"), ("1_000", "1000"), ("007", "7"),
    ]
    out_of_range = ["2147483648", "4294967296", "0xFFFFFFFF"]
    cases = []
    for text, want in forms:
        cases.append(Case("int-literal-bind",
                          "val x: int = %s\nprint(x)" % text, "either", want,
                          "in a binding, not in a call"))
    for text in out_of_range:
        cases.append(Case("int-literal-bind",
                          "val x: int = %s\nprint(x)" % text, "reject", None,
                          "out of range for orbit_int (32-bit signed)"))
    return cases


def arith_cases(rng, n_arith):
    """The four integer operators over signed operands.

    `n_arith` counts CASES, so the pair count is divided by the five operators.
    """
    interesting = [0, 1, -1, 2, -2, 3, 7, -7, 10, -10, 100, -100,
                   INT_MAX, INT_MAX - 1, INT_MIN, INT_MIN + 1, 65536, -65536,
                   2147483646, -2147483647, 1073741824, -1073741824]
    pairs = [(a, b) for a in interesting for b in interesting if b != 0]
    rng.shuffle(pairs)
    pairs = pairs[:max(0, n_arith // 5 - 120)]
    for _ in range(max(0, n_arith // 5 - len(pairs))):
        pairs.append((rng.randrange(INT_MIN, INT_MAX + 1),
                      rng.randrange(INT_MIN, INT_MAX + 1)))
    cases = []
    for a, b in pairs:
        b = b or 1  # division by zero is its own class
        for op, ref in (("+", lambda x, y: i32(x + y)),
                        ("-", lambda x, y: i32(x - y)),
                        ("*", lambda x, y: i32(x * y)),
                        ("/", c_div),
                        ("%", c_mod)):
            if a == INT_MIN and b == -1 and op in "/%":
                continue  # overflows on x86; div-zero class covers the signal
            cases.append(Case("int-arith", "print((%d) %s (%d))" % (a, op, b),
                              "value", str(ref(a, b))))
    return cases


def divzero_cases():
    """Division and modulo by zero, and the sign of a negative result."""
    cases = []
    for a in (1, -1, 7, -7, 0, INT_MAX, INT_MIN):
        for op in ("/", "%"):
            cases.append(Case("div-zero", "print((%d) %s 0)" % (a, op), "diagnose", None,
                              "division by zero must be a diagnostic, not a signal"))
    cases.append(Case("div-zero", "print((%d) / -1)" % INT_MIN, "diagnose", None,
                      "INT_MIN / -1 overflows on x86 and raises SIGFPE"))
    cases.append(Case("div-zero", "print((%d) %% -1)" % INT_MIN, "diagnose", None,
                      "INT_MIN %% -1 is defined and equals 0"))
    # the sign of a result, which is the half of F-0014 that a log hides
    for a, b in ((-7, 2), (-7, 3), (-7, 10), (7, -2), (7, -3), (-1, 2), (1, -2)):
        cases.append(Case("div-zero", "print((%d) / (%d))" % (a, b), "value",
                          str(c_div(a, b))))
        cases.append(Case("div-zero", "print((%d) %% (%d))" % (a, b), "value",
                          str(c_mod(a, b))))
    return cases


# Escape handling, stated as a table so the expectation is a decision and not
# an accident of what Orbit happens to do.
#
# The reference implements what the language DOCUMENTS, not what C does. That
# distinction is the whole content of this section, so it is argued here rather
# than left implicit, because getting it wrong is how a fuzzer ends up
# reporting 24 permanent "disagreements" that nobody will ever fix and everybody
# learns to ignore.
#
# docs/LANGUAGE_REFERENCE.md ("Arrays and objects") says: "An ordinary string
# supports \n, \t, \r, \", \\, and the byte escape \xHH with two hex digits ...
# Anything malformed stays literal."
#
# So the rule is total: decode the escapes this language has, and write back
# exactly what the author wrote for everything else. Nothing needs a table of
# the escapes it does not have, which is why the fallback is safe. The
# alternative -- decode what C decodes -- is not a smaller rule, it is a
# different and much larger one: C's set is a table with rules of its own
# (\0 starts an octal escape, \x is greedy, \e is not standard at all), and
# every escape still outside it is a guess about what the author meant. Guessing
# is how `"\q"` becomes some other character and nobody can tell why.
#
# The three classes this moved, measured before the change, 24 cases in all:
#
#   string-escape/c-escape-is-kept-as-two-characters              17
#   string-escape/malformed-hex-escape-is-kept-literal             6
#   string-escape/unknown-escape-is-kept-literal                   1
#
# All three were the reference saying "C would decode this" about a language
# that documents six escapes. They are now ASSERTED agreements, which is a
# stronger pin than a note: if the escape behaviour ever changes, the count goes
# up and the ratchet fires. Reversing the decision is a deliberate act -- edit
# the table below, and the corpus sha moves with it.
#
# What is left in this class is one case, and it is a bug and not a decision:
# `\x00` is two hex digits, so the documented rule covers it, and the compiler
# does not decode it (F-0020, `compiler/builder.orb:2481` tests the SUM of the
# two nibbles against zero instead of testing that both digits are valid). There
# is no reading of the documentation under which `\x00` stays literal.
DOCUMENTED_ESCAPES = {"n": 0x0A, "t": 0x09, "r": 0x0D, '"': 0x22, "\\": 0x5C}

# The C escapes this language does not have. Listed so the table above can be
# argued with: every one of these is a case where the compiler and C disagree
# on purpose today, and the corpus asserts the compiler.
C_ESCAPES_NOT_HERE = ("\\a", "\\b", "\\f", "\\v", "\\e", "\\0", "\\'")


class Unterminated(ValueError):
    """A string literal that never closes.

    Not a malformed ESCAPE: the backslash is not the problem, the missing quote
    is, and the parser already says so. It stays a `reject` expectation because
    the correct answer really is a diagnostic.
    """


def documented_unescape(body):
    """Decode the text BETWEEN two pairs of double quotes, as the language says.

    Raises Unterminated for a trailing backslash, which is an unterminated
    literal rather than a malformed escape. Everything else has a defined value,
    including the malformed escapes: they are the two characters the author
    wrote, which is what "stays literal" means and is the only total rule.
    """
    out_bytes = bytearray()
    i = 0
    while i < len(body):
        ch = body[i]
        if ch != "\\":
            out_bytes += ch.encode("utf-8")
            i += 1
            continue
        if i + 1 >= len(body):
            raise Unterminated("trailing backslash: the literal never closes")
        nxt = body[i + 1]
        if nxt == "x":
            hexpart = body[i + 2:i + 4]
            if len(hexpart) == 2 and re.fullmatch(r"[0-9a-fA-F]{2}", hexpart):
                out_bytes.append(int(hexpart, 16))
                i += 4
                continue
            # Malformed \x: not an escape this literal has, so the two
            # characters stay and whatever followed is ordinary text.
            out_bytes += b"\\x"
            i += 2
            continue
        if nxt in DOCUMENTED_ESCAPES:
            out_bytes.append(DOCUMENTED_ESCAPES[nxt])
            i += 2
            continue
        # Not an escape this language has: write what the author wrote. The
        # backslash goes out now and the next character is copied as ordinary
        # text by the next turn of the loop, which is the same two bytes.
        out_bytes += b"\\"
        i += 1
    return bytes(out_bytes)


def escape_cases(rng, n_escapes):
    """Well-formed escapes, C escapes the language does not document, and the
    malformed ones.

    Every body here has a defined value now, including the malformed ones, so
    every case is a `bytes` comparison except the unterminated literal. That is
    the point of the reclassification above: a case whose expectation is "or a
    refusal" cannot tell a language that decided from a language that gave up.
    """
    bodies = [
        ("\\n", "newline"), ("\\t", "tab"), ("\\r", "carriage return"),
        ('\\"', "double quote"), ("\\\\", "backslash"),
        ("\\x41", "hex A"), ("\\x00", "hex NUL"), ("\\x7F", "hex DEL"),
        ("\\xFF", "hex high byte"),
        ("a\\nb", "newline inside"), ("a\\tb\\rc", "several"),
        ("\\x41\\x42\\x43", "three hex bytes"),
        # escapes a C reader expects and this language does not document
        ("\\a", "bell"), ("\\b", "backspace"), ("\\f", "form feed"),
        ("\\v", "vertical tab"), ("\\e", "escape"), ("\\0", "NUL"),
        ("\\'", "single quote"),
        ("a\\0b", "NUL inside a word"),
        # malformed: documented as staying literal, so that is the value
        ("\\x", "hex with no digits"), ("\\x4", "hex with one digit"),
        ("\\xZZ", "hex with non-hex"), ("\\q", "unknown letter"),
        ("\\", "trailing backslash"),
    ]
    for _ in range(max(0, n_escapes - len(bodies))):
        pool = "abZ019 _"
        body = "".join("\\" + rng.choice("ntrax0e") if rng.random() < 0.5
                       else rng.choice(pool) for _ in range(rng.randrange(1, 5)))
        bodies.append((body, "seeded"))
    cases = []
    for body, note in bodies:
        try:
            expect = documented_unescape(body)
        except Unterminated as exc:
            cases.append(Case("string-escape", 'print("%s")' % body, "reject", None,
                              "%s: %s" % (note, exc)))
            continue
        cases.append(Case("string-escape", 'print("%s")' % body, "bytes", expect,
                          note))
    return cases


def float_cases(rng, n_floats):
    """Float round-tripping. Floats do not work at all today (F-0016)."""
    lits = ["1.5", "2.0", "0.1", "3.14159", "100.0", "0.5", "-2.25", "1e0" ]
    for _ in range(max(0, n_floats - len(lits))):
        lits.append("%d.%02d" % (rng.randrange(0, 1000), rng.randrange(0, 100)))
    cases = []
    for text in lits:
        try:
            expect = repr(float(text))
        except ValueError:
            continue
        # An exponent form does not exist yet, so refusing it is correct and
        # answering a truncated integer is not; the `either` kind says exactly
        # that, and starts checking the value the day it is implemented.
        kind = "either" if "e" in text else "value"
        cases.append(Case("float", "print(%s)" % text, kind, expect,
                          "exponent form" if kind == "either" else "literal"))
    for expr, ref in (("1.5 + 1.5", lambda: 3.0), ("0.5 * 4.0", lambda: 2.0),
                      ("3.0 / 2.0", lambda: 1.5), ("1.0 - 0.25", lambda: 0.75)):
        cases.append(Case("float", "print(%s)" % expr, "value", repr(ref()), expr))
    return cases


# --------------------------------------------------------------------------
# Running.
# --------------------------------------------------------------------------
class Runner:
    def __init__(self, compiler, cc, work, timeout=120):
        self.compiler = compiler
        self.cc = cc
        self.work = work
        self.timeout = timeout
        self.programs = 0

    def _env(self):
        env = dict(os.environ)
        env["ORBIT_CC"] = self.cc
        env["CC"] = self.cc
        env["TEMP"] = self.work
        env["TMP"] = self.work
        return env

    def _build(self, source, index):
        """Write a program and run it. Returns (status, stdout_bytes, note)."""
        path = os.path.join(self.work, "case_%05d.orb" % index)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(source)
        try:
            proc = subprocess.run([self.compiler, "run", path], cwd=ROOT,
                                  env=self._env(), capture_output=True,
                                  timeout=self.timeout)
        except subprocess.TimeoutExpired:
            return "hung", b"", "no exit after %ds" % self.timeout
        self.programs += 1
        if proc.returncode in (1, 2):
            return "rejected", proc.stdout, ""
        if proc.returncode < 0 or proc.returncode >= 128:
            return "crashed", proc.stdout, "died on signal (rc=%d)" % proc.returncode
        if proc.returncode != 0:
            return "error", proc.stdout, "rc=%d: %s" % (
                proc.returncode, (proc.stderr or b"").decode("utf-8", "replace")[-200:])
        return "ok", proc.stdout, ""

    def run_source(self, source, index):
        return self._build(source, index)

    def run_batch(self, cases, index):
        """Many one-line cases in one program, compared line by line.

        A build+run costs about as much whatever the program contains, so 40
        cases in one program is 40x the corpus for the same seconds. The
        contract is one output line per case, which holds because every value
        case prints exactly one integer. When the program does not deliver that
        -- it crashed, or a value printed more than one line -- the caller falls
        back to running the cases one at a time, so a batch can never hide a
        finding behind an attribution failure.
        """
        source = "fn main() -> int {\n" + "".join("    %s\n" % c.source
                                                   for c in cases) + "    return 0\n}\n"
        status, stdout, note = self._build(source, index)
        if status != "ok":
            if not note:
                note = "the batched program was %s" % (
                    "refused to compile" if status == "rejected" else status)
            return None, status, note
        lines = stdout.decode("utf-8", "replace").splitlines()
        if len(lines) != len(cases):
            return None, status, "produced %d lines for %d cases" % (len(lines), len(cases))
        return lines, status, note

    def run_bytes_batch(self, cases, index):
        """String cases in one program, each framed so its output is findable.

        The output is bytes and can contain newlines, so line splitting does not
        work; each case is printed between two sentinel lines instead, and the
        bytes between them are compared exactly. The sentinel is a fixed string
        the generator can never produce inside a body.
        """
        # One sentinel BEFORE each case and one at the very end, never two in
        # a row: a doubled sentinel would put an empty region between
        # neighbours, which is indistinguishable from a case that printed
        # nothing. The framing is then S b1 S b2 ... S bn S, which splits into
        # exactly n bodies.
        source = ("fn main() -> int {\n"
                  + "".join('    print("%s")\n    %s\n' % (SENTINEL, c.source)
                            for c in cases)
                  + '    print("%s")\n' % SENTINEL
                  + "    return 0\n}\n")
        status, stdout, note = self._build(source, index)
        if status != "ok":
            if not note:
                note = "the batched program was %s" % (
                    "refused to compile" if status == "rejected" else status)
            return None, status, note
        marker = SENTINEL.encode() + b"\n"
        if not stdout.startswith(marker):
            return None, status, "output does not start with the sentinel"
        # n cases produce n+1 sentinels, so n+1 regions, of which the first and
        # last are empty. Each region carries the newline `print` added.
        regions = stdout.split(marker)
        bodies = regions[1:-1]
        if len(bodies) != len(cases):
            return None, status, ("framing gave %d regions for %d cases"
                                  % (len(bodies), len(cases)))
        return [b[:-1] if b.endswith(b"\n") else b for b in bodies], status, note


def observed_of(case, status, stdout):
    """What Orbit actually did, in the same shape the report prints."""
    if status == "rejected":
        return "refused to compile (no diagnostic named)"
    if status == "crashed":
        return "died on a signal"
    if isinstance(case.expect, bytes):
        return repr(_one_nl_off(stdout))
    text = stdout.decode("utf-8", "replace").strip()
    return text if text else "(printed nothing)"


def check_reject(case, status, note):
    if status == "rejected":
        return None
    if status == "ok":
        return "accepted a program it must reject: %s" % (case.note or "no diagnostic")
    if status == "crashed":
        return "crashed instead of diagnosing: %s" % note
    return "failed to build for the wrong reason: %s" % note


def check_diagnose(case, status, note, stdout=b""):
    if status == "rejected":
        return None
    if status == "crashed":
        return "died on a signal instead of diagnosing: %s" % note
    if status == "hung":
        return "hung instead of diagnosing: %s" % note
    return ("answered %r where the only correct answers are a diagnostic or a "
            "refusal" % stdout.decode("utf-8", "replace").strip())


def _one_nl_off(data):
    """`print` adds exactly one newline; a case's expectation does not have it."""
    return data[:-1] if data.endswith(b"\n") else data


def check_bytes(case, got):
    if got == case.expect:
        return None
    return "wrong bytes: got %s, want %s" % (repr(got), repr(case.expect))


# --------------------------------------------------------------------------
# The sweep.
# --------------------------------------------------------------------------
def sweep(runner, corpus, batch, verbose=True):
    """Run the whole corpus. Returns (findings, agree, by_category)."""
    findings = []
    agree = 0
    by_category = {}

    def record(case, problem, status, stdout=b""):
        if problem is None:
            return True
        findings.append({"category": case.category, "kind": case.kind,
                         "source": case.source,
                         "expect": (repr(case.expect)
                                    if isinstance(case.expect, bytes)
                                    else case.expect),
                         "note": case.note, "problem": problem, "status": status,
                         "observed": observed_of(case, status, stdout),
                         "class": class_of(case, problem)})
        return False

    def tally(case):
        stats = by_category.setdefault(case.category, [0, 0])
        stats[0] += 1
        return stats

    index = 0
    # `either` cases ride with the value cases so a batch can hold them, and
    # they are the one kind that treats a refusal as a pass.
    value_cases = [c for c in corpus
                   if c.kind in ("value", "either") and "\n" not in c.source]
    bytes_cases = [c for c in corpus if c.kind == "bytes"]
    single_cases = [c for c in corpus
                    if c.kind in ("reject", "diagnose") or "\n" in c.source]

    def judge_one(case, status, stdout):
        if status != "ok":
            if status == "crashed":
                return "crashed instead of answering (%s)" % stdout.decode(
                    "utf-8", "replace")[:120]
            if status == "hung":
                return "hung: no answer at all"
            if case.kind == "either":
                return None
            if status == "rejected":
                return ("rejected a program with a defined answer (%s)"
                        % (case.note or case.expect))
            return "failed to build: %s" % stdout.decode("utf-8", "replace")[:120]
        got = stdout.decode("utf-8", "replace").strip()
        if got == case.expect:
            return None
        if case.kind == "either":
            return ("answered %r where the only correct answers are %r or a "
                    "refusal: %s" % (got, case.expect, case.note))
        return "wrong value: got %r, want %r" % (got, case.expect)

    for start in range(0, len(value_cases), batch):
        chunk = value_cases[start:start + batch]
        index += 1
        lines, status, note = runner.run_batch(chunk, index)
        if lines is not None:
            for case, line in zip(chunk, lines):
                stats = tally(case)
                problem = judge_one(case, "ok", line.encode("utf-8", "replace"))
                if record(case, problem, "ok", line.encode("utf-8", "replace")):
                    stats[1] += 1
                    agree += 1
            continue
        if verbose:
            out.say("  batch of %d did not line up (%s: %s); attributing it"
                    % (len(chunk), status, note))
        # A batch that was REFUSED has at least one unparseable case in it and
        # the rest are innocent, so halve it rather than running 40 programs.
        # A batch that crashed or misaligned has to be split all the way down,
        # because then any case in it could be the culprit.
        if status == "rejected" and len(chunk) > 1:
            mid = len(chunk) // 2
            halves = [chunk[:mid], chunk[mid:]]
        else:
            halves = [[c] for c in chunk]
        for half in halves:
            index += 1
            sub_lines, sub_status, sub_note = runner.run_batch(half, index)
            if sub_lines is not None:
                for case, line in zip(half, sub_lines):
                    stats = tally(case)
                    problem = judge_one(case, "ok", line.encode("utf-8", "replace"))
                    if record(case, problem, "ok", line.encode("utf-8", "replace")):
                        stats[1] += 1
                        agree += 1
                continue
            for case in half:
                index += 1
                st, stdout, nt = runner.run_source(case.program(), index)
                stats = tally(case)
                if record(case, judge_one(case, st, stdout), st, stdout):
                    stats[1] += 1
                    agree += 1

    for start in range(0, len(bytes_cases), batch):
        chunk = bytes_cases[start:start + batch]
        index += 1
        bodies, status, note = runner.run_bytes_batch(chunk, index)
        if bodies is not None:
            for case, body in zip(chunk, bodies):
                stats = tally(case)
                if record(case, check_bytes(case, body), "ok", body):
                    stats[1] += 1
                    agree += 1
            continue
        if verbose:
            out.say("  byte batch of %d did not frame (%s); one at a time"
                    % (len(chunk), note))
        for case in chunk:
            index += 1
            st, stdout, nt = runner.run_source(case.program(), index)
            stats = tally(case)
            if st == "ok":
                problem = check_bytes(case, _one_nl_off(stdout))
            elif st == "rejected":
                problem = "rejected a well-formed string literal"
            elif st == "crashed":
                problem = "crashed on a string literal: %s" % nt
            else:
                problem = "failed to build: %s" % nt
            if record(case, problem, st, stdout):
                stats[1] += 1
                agree += 1

    # reject / diagnose are one program each: a program that must be refused
    # takes the whole program down, so there is nothing to batch it with.
    for case in single_cases:
        index += 1
        st, stdout, nt = runner.run_source(case.program(), index)
        stats = tally(case)
        if case.kind == "reject":
            problem = check_reject(case, st, nt)
        elif case.kind == "diagnose":
            problem = check_diagnose(case, st, nt, stdout)
        else:
            problem = judge_one(case, st, stdout)
        if record(case, problem, st, stdout):
            stats[1] += 1
            agree += 1
    return findings, agree, by_category


# --------------------------------------------------------------------------
def build_corpus(seed, iterations, categories):
    """The corpus, in a fixed order, from a fixed seed. Same every run."""
    rng = random.Random(seed)
    n = max(0, iterations)
    quarter = max(40, n // 4)
    corpus = []
    if "int-literal" in categories:
        corpus += literal_cases(rng, quarter)
    if "int-literal-bind" in categories:
        corpus += bind_cases()
    if "int-arith" in categories:
        corpus += arith_cases(rng, n)
    if "div-zero" in categories:
        corpus += divzero_cases()
    if "string-escape" in categories:
        corpus += escape_cases(rng, quarter // 2)
    if "float" in categories:
        corpus += float_cases(rng, min(quarter, 40))
    return corpus


def corpus_digest(corpus):
    h = hashlib.sha256()
    for case in corpus:
        h.update(("%s\x00%s\x00%s\x00%s\n" % (case.category, case.source,
                                               case.kind, case.expect)).encode())
    return h.hexdigest()[:16]


def class_of(case, problem):
    """Group disagreements by mechanism, so 400 cases are 8 findings, not 400.

    The class name is the finding. Everything in a class has one cause, so
    whoever fixes it fixes all of them, and the count says how wide it is.
    """
    if case.category == "string-escape":
        body = case.source[len('print("'):-len('")')]
        if body == "\\":
            return "string-escape/unterminated-literal-is-accepted"
        if "\\x00" in body or "\\x0" in body and case.expect == b"\x00":
            return "string-escape/hex-zero-is-never-decoded"
        if case.kind == "reject":
            return "string-escape/unterminated-literal-is-accepted"
        if any(e in body for e in C_ESCAPES_NOT_HERE):
            return "string-escape/c-escape-is-kept-as-two-characters"
        return "string-escape/wrong-bytes"
    if case.category == "int-literal-bind":
        if "out of range" in case.note:
            return "int-literal/out-of-range-literal-is-accepted"
        return "int-literal/unsupported-form-is-silently-wrong-in-a-binding"
    if case.category == "int-literal":
        if "out of range" in case.note:
            return "int-literal/out-of-range-literal-is-accepted"
        if "form does not exist yet" in case.note:
            return "int-literal/unsupported-literal-form-answers-wrongly"
        if "separates digits in decimal" in case.note:
            return "int-literal/underscore-works-in-decimal-but-not-in-hex"
        return "int-literal/wrong-value"
    if case.category == "int-arith":
        if " / " in case.source:
            return "int-arith/wrong-division"
        if " % " in case.source:
            return "int-arith/wrong-modulo"
        return "int-arith/wrong-value"
    if case.category == "div-zero":
        if case.kind == "diagnose":
            return "div-zero/signal-instead-of-a-diagnostic"
        return "div-zero/wrong-sign"
    if case.category == "float":
        if case.kind == "either":
            return "float/exponent-form-is-not-a-float"
        return "float/truncated-to-an-integer"
    return "%s/other" % case.category


def main():
    ap = argparse.ArgumentParser(
        description="Differential fuzzer: Orbit vs a reference implementation")
    ap.add_argument("--compiler", default=os.path.join(ROOT, "orbit.exe"))
    ap.add_argument("--cc", default="gcc", help="inline, for run/build")
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--iterations", type=int, default=400,
                    help="size of the generated part of the corpus (default 400)")
    ap.add_argument("--only", action="append", default=None,
                    help="restrict to a category (repeatable): %s"
                         % ", ".join(CATEGORIES))
    ap.add_argument("--batch", type=int, default=40,
                    help="how many one-line cases share one program (default 40; "
                         "a build costs the same whatever the program contains)")
    ap.add_argument("--json", default=None, help="write every finding to this file")
    ap.add_argument("--top", type=int, default=12,
                    help="how many example programs to print per class")
    ap.add_argument("--strict", action="store_true",
                    help="exit non-zero when any case disagrees (report-only "
                         "by default: a fuzzer that fails the build the day a "
                         "finding appears is one that gets switched off)")
    ap.add_argument("--list", action="store_true",
                    help="print the corpus without running anything")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    categories = tuple(args.only) if args.only else CATEGORIES
    for c in categories:
        if c not in CATEGORIES:
            out.fail("Failed diff-fuzz: unknown category %r; known: %s"
                     % (c, ", ".join(CATEGORIES)))
            return 1

    corpus = build_corpus(args.seed, args.iterations, categories)
    digest = corpus_digest(corpus)
    if not corpus:
        out.fail("Failed diff-fuzz: the corpus is empty")
        return 1

    if args.list:
        for case in corpus:
            print("%-14s %-9s %-46s %s" % (case.category, case.kind, case.label(),
                                            case.expect))
        print("Finished diff-fuzz corpus: %d cases, sha %s" % (len(corpus), digest))
        return 0

    out.say("Differential fuzz: %d cases, seed %d, corpus sha %s, reference is "
            "Python 3 with 32-bit ints and truncating / and %%"
            % (len(corpus), args.seed, digest))
    work = os.path.join(os.environ.get("TMPDIR", "/tmp"), "orbit_difffuzz")
    os.makedirs(work, exist_ok=True)
    runner = Runner(args.compiler, args.cc, work)

    findings, agree, by_category = sweep(runner, corpus, max(1, args.batch),
                                         verbose=not out.is_quiet())
    out.say("Ran %d program(s) for %d cases" % (runner.programs, len(corpus)))

    # ---- report ---------------------------------------------------------
    groups = {}
    for f in findings:
        groups.setdefault(f["class"], []).append(f)

    for name in sorted(groups):
        items = groups[name]
        worst = items[0]
        out.fail("Disagreement %s (%d case%s)" % (name, len(items),
                                                   "" if len(items) == 1 else "s"))
        out.fail("  %s" % worst["problem"])
        for f in items[:args.top]:
            out.fail("  minimal program: %s" % f["source"])
            out.fail("    orbit: %s" % f["observed"])
            if isinstance(f["expect"], bytes):
                out.fail("    ref:   %s" % repr(f["expect"]))
            elif f["expect"] is not None:
                out.fail("    ref:   %s" % f["expect"])
            if f["note"]:
                out.fail("    case:  %s" % f["note"])
        if len(items) > args.top:
            out.fail("  ... and %d more of this class" % (len(items) - args.top))

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            # `iterations` and `batch` are recorded because the ratchet writes
            # them into its baseline: a count with no corpus parameters behind
            # it is a number nobody can reproduce. Neither is part of the corpus
            # identity -- the sha is over the case list -- so adding them does
            # not move it.
            json.dump({"seed": args.seed, "iterations": args.iterations,
                       "batch": args.batch, "corpus_sha": digest,
                       "cases": len(corpus), "agree": agree,
                       "findings": findings}, fh, indent=2)
            fh.write("\n")
        out.say("Wrote every finding to %s" % args.json)

    for name in CATEGORIES:
        if name in by_category:
            total, ok = by_category[name]
            out.say("  %-14s %4d cases, %4d agree, %4d disagree"
                    % (name, total, ok, total - ok))

    print("Finished diff-fuzz: %d/%d agree with the reference across %d cases "
          "(seed %d, sha %s)" % (agree, len(corpus), len(corpus), args.seed, digest))
    if findings:
        print("  %d disagreement(s) in %d class(es). REPORT ONLY unless --strict."
              % (len(findings), len(groups)))
        out.tip("each one is a program that compiles clean, runs, and gives the "
                "wrong answer. --json keeps the full list.")
    return 1 if (findings and args.strict) else 0


if __name__ == "__main__":
    raise SystemExit(main())
