// node editors/vscode/test/diagnostics_test.js
//
// Every fixture below is the verbatim output of `orbit check` on a file, so
// this fails the moment the compiler changes a diagnostic's shape. Run it
// with plain node; there is no test framework in the extension.

'use strict';

const assert = require('assert');
const { parseDiagnostics } = require('../diagnostics');

let failures = 0;
function test(name, fn) {
    try {
        fn();
        console.log('ok   ' + name);
    } catch (err) {
        failures++;
        console.log('FAIL ' + name);
        console.log('     ' + err.message);
    }
}

test('semantic error, no position', () => {
    const out = parseDiagnostics(
        'Semantic error: Return type mismatch: expected float, got int [in f]\n'
    );
    assert.deepStrictEqual(out, [{
        code: 'orbit-semantic',
        message: 'Return type mismatch: expected float, got int',
        line: null,
        column: null,
    }]);
});

test('several semantic errors keep their order', () => {
    const out = parseDiagnostics(
        'Semantic error: Return type mismatch: expected float, got int [in f]\n' +
        'Semantic error: Return type mismatch: expected bool, got int [in g]\n'
    );
    assert.strictEqual(out.length, 2);
    assert.ok(out[0].message.indexOf('float') !== -1);
    assert.ok(out[1].message.indexOf('bool') !== -1);
});

test('parser error carries the line it named', () => {
    const out = parseDiagnostics(
        "Parser error at line 1: 'private' is not supported on types yet.\n"
    );
    assert.strictEqual(out[0].code, 'orbit-parse');
    assert.strictEqual(out[0].line, 0);
    assert.strictEqual(out[0].message, "'private' is not supported on types yet.");
});

test('import error', () => {
    const out = parseDiagnostics(
        'Import error: Could not read imported module: std/nope.orb\n'
    );
    assert.strictEqual(out[0].code, 'orbit-import');
    assert.strictEqual(out[0].message, 'Could not read imported module: std/nope.orb');
});

// Verbatim from `orbit check` on `fn main() -> int { val x = 1 +  }`.
test('rustc-style block with a column', () => {
    const out = parseDiagnostics([
        '',
        "error[E0301]: unexpected token 'CloseBrace'",
        '  --> d4.orb:1:34',
        '   |',
        ' 1 | fn main() -> int { val x = 1 +  }',
        '   |                                  ^-- here',
        '   |',
        '   = help: Check for missing brackets, quotes, or keywords before this token.',
        '',
        'ERROR: error.UnexpectedToken',
        '',
    ].join('\n'));
    assert.strictEqual(out.length, 1);
    assert.strictEqual(out[0].code, 'orbit-E0301');
    assert.strictEqual(out[0].line, 0);
    assert.strictEqual(out[0].column, 33);
    assert.strictEqual(out[0].message, "unexpected token 'CloseBrace'");
});

test('a clean check produces no diagnostics', () => {
    assert.deepStrictEqual(parseDiagnostics('Checked d6.orb: no errors.\n'), []);
    assert.deepStrictEqual(parseDiagnostics(''), []);
});

test('C step failure text does not become a phantom diagnostic', () => {
    const out = parseDiagnostics(
        'orbit build: couldn\'t finish the C step - this one is on me, not your code.\n' +
        '  <build>:2:10: fatal error: socket_compat.h: No such file or directory\n'
    );
    assert.deepStrictEqual(out, []);
});

if (failures > 0) {
    console.log('\n' + failures + ' failing');
    process.exit(1);
}
console.log('\nall passing');
