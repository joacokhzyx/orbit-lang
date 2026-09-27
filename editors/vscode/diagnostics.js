// Parses what `orbit check` writes, with no VS Code dependency, so it can be
// exercised by `node editors/vscode/test/diagnostics_test.js`.
//
// The two shapes below are the only two the compiler emits, taken from
// compiler/pipeline.orb: rustc-style blocks for the parser (it has a
// Lexer/Parser with positions) and one flat line for sema and the resolver
// (they carry a message and sometimes a line number, never a column).

'use strict';

// error[E0301]: unexpected token 'CloseBrace'
//   --> d4.orb:1:34
const HEAD = /^error\[([A-Za-z0-9]+)\]:\s*(.*)$/;
const LOCATION = /^\s*-->\s*(.+?):(\d+):(\d+)\s*$/;
const PARSER = /^Parser error at line (\d+):\s*(.*)$/;
const SEMANTIC = /^Semantic error:\s*(.*?)(?:\s*\[in [^[\]]+\])?\s*$/;
const IMPORT = /^Import error:\s*(.*)$/;

// Returns [{ code, message, line, column }] with zero-based line and column.
// `line` is null when the compiler did not say where the problem is; the
// caller decides what to anchor it to.
function parseDiagnostics(text) {
    const lines = text.split(/\r?\n/);
    const found = [];

    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];

        const head = line.match(HEAD);
        if (head) {
            const loc = findLocation(lines, i + 1);
            found.push({
                code: 'orbit-' + head[1],
                message: head[2].trim(),
                line: loc ? loc.line : null,
                column: loc ? loc.column : null,
            });
            continue;
        }

        const parser = line.match(PARSER);
        if (parser) {
            found.push({
                code: 'orbit-parse',
                message: parser[2].trim(),
                line: Math.max(parseInt(parser[1], 10) - 1, 0),
                column: null,
            });
            continue;
        }

        const semantic = line.match(SEMANTIC);
        if (semantic) {
            found.push({
                code: 'orbit-semantic',
                message: semantic[1].trim(),
                line: null,
                column: null,
            });
            continue;
        }

        const importError = line.match(IMPORT);
        if (importError) {
            found.push({
                code: 'orbit-import',
                message: importError[1].trim(),
                line: null,
                column: null,
            });
            continue;
        }
    }
    return found;
}

function findLocation(lines, from) {
    // The "-->" line is 1-3 lines below the message: the blank line, the
    // location, and the "|" rule. Look a short way ahead, no further, so a
    // later error's location is not stolen by an earlier one.
    for (let i = from; i < Math.min(from + 3, lines.length); i++) {
        const m = lines[i].match(LOCATION);
        if (m) {
            return {
                line: Math.max(parseInt(m[2], 10) - 1, 0),
                column: Math.max(parseInt(m[3], 10) - 1, 0),
            };
        }
    }
    return null;
}

module.exports = { parseDiagnostics };
