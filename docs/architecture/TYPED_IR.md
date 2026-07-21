# Orbit Typed IR (TIR) v1

`TIR` is the boundary between the self-hosted Orbit frontend and every code
generator.  It is deliberately a language contract rather than an in-memory
Zig API: a frontend must be able to emit it without linking or importing Zig.

## Scope

The frontend accepts one or more `.orb` source units and emits exactly one
module.  A valid module contains:

- declarations in source/module order;
- resolved names (no unresolved identifier nodes);
- an explicit type for every value-producing instruction;
- stable numeric ids for functions, values and blocks;
- structured diagnostics with source coordinates.

The C and native backends consume this module.  Neither backend is allowed to
recover syntax, infer types, or depend on a frontend implementation detail.

## Canonical text encoding

The initial interchange encoding is UTF-8 text.  It makes bootstrap artifacts
inspectable and lets Stage 2/Stage 3 compare frontend output byte-for-byte.

```text
orbit-tir 1
module <escaped module name>
function <id> <escaped name> <escaped return type>
param <function id> <index> <escaped name> <escaped type>
block <function id> <block id>
instr <function id> <block id> <value id> <escaped opcode> <escaped type> <escaped operand text>
end-function <id>
```

`<escaped …>` uses backslash escaping: `\\`, `\n`, `\r` and `\t`.  A newline is
always `\n`; no platform-dependent line ending is permitted.  Functions,
parameters, blocks and instructions are emitted in their stored order.  The
frontend assigns ids monotonically, starting at zero for each id domain.

## Invariants

1. TIR is emitted only when there are no error diagnostics.
2. A value id is unique inside a function; a block id is unique inside it too.
3. Every instruction has a non-empty, resolved opcode and type. `unknown` is
   an analysis-only sentinel and must make emission fail. `unit` is used for
   statements that do not create a language value.
4. Parameters use their ordinal position, not map iteration order.
5. Diagnostic order is source order, then emission order for diagnostics at
   the same source position.

## Migration path

Stage 0 may use the Zig compiler solely to compile the Orbit frontend binary.
That binary emits TIR.  The temporary Zig bridge reads TIR and adapts it to the
existing C/native backend structures.  Removing that bridge is the backend
milestone; it must not change this format or move parsing/type checking back
into a backend.
