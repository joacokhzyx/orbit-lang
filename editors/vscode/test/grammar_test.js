// node editors/vscode/test/grammar_test.js
//
// Structural tests for the TextMate grammar and the snippets: every include
// resolves, key rules match what the lexer accepts and reject what it does
// not, and every snippet is well-formed and teaches nothing removed.
// A full tokenization check would need vscode-textmate; the spot lists here
// catch the "edited grammar, dropped a rule" class instead.

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname, '..');
const grammar = JSON.parse(fs.readFileSync(path.join(dir, 'syntaxes', 'orbit.tmLanguage.json'), 'utf8'));
const snippets = JSON.parse(fs.readFileSync(path.join(dir, 'snippets', 'orbit.json'), 'utf8'));

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

function repo(name) {
    const entry = grammar.repository[name];
    assert.ok(entry, 'missing repository entry: ' + name);
    return JSON.stringify(entry);
}

test('manifest shape: scope and includes resolve', () => {
    assert.strictEqual(grammar.scopeName, 'source.orbit');
    const includes = [];
    const walk = node => {
        if (Array.isArray(node)) {
            node.forEach(walk);
        } else if (node && typeof node === 'object') {
            for (const [k, v] of Object.entries(node)) {
                if (k === 'include' && typeof v === 'string' && v.startsWith('#')) {
                    includes.push(v.slice(1));
                } else {
                    walk(v);
                }
            }
        }
    };
    walk(grammar.patterns);
    assert.ok(includes.length > 0);
    for (const name of new Set(includes)) {
        assert.ok(grammar.repository[name], 'dangling include: #' + name);
    }
});

test('numbers track the lexer: binary, octal, exponent', () => {
    const src = repo('numbers');
    assert.ok(/0\[bB\]/.test(src), 'no binary arm');
    assert.ok(/0\[oO\]/.test(src), 'no octal arm');
    assert.ok(/eE/.test(src), 'no exponent arm');
});

test('constants are true/false only; config names migrations', () => {
    const match = grammar.repository.constants.patterns[0].match;
    assert.ok(new RegExp(match).test('true'));
    assert.ok(!new RegExp(match).test('null'), 'null is not a literal');
    assert.ok(repo('config-keys').includes('migrations'));
});

test('operators have no phantom tokens', () => {
    const src = repo('operators');
    assert.ok(!src.includes('\\?'), 'spurious ? operator');
    assert.ok(!src.includes('\\+='), 'spurious += operator');
    assert.ok(src.includes('\\|'), 'missing bare |');
    assert.ok(src.includes('<<') && src.includes('>>'), 'missing shift operators the lexer produces');
    assert.ok(src.includes('~') && src.includes('^'), 'missing ~ / ^ the lexer produces');
});

test('char literal has no xHH escape', () => {
    const src = repo('strings');
    const charRule = grammar.repository.strings.patterns[2].match;
    assert.ok(charRule, 'char rule lost its match');
    assert.ok(!charRule.includes('x['), 'char rule allows \\xHH the lexer rejects');
});

test('statement rules exist: route, object keys, builtins, limit, schedule', () => {
    for (const name of ['route-decl', 'object-keys', 'builtins', 'rate-limit', 'schedule', 'doc-tags']) {
        repo(name);
    }
    assert.ok(repo('route-decl').includes('route-param'));
    assert.ok(repo('builtins').includes('bearer_token'));
    assert.ok(repo('builtins').includes('latency_p99_us'));
});

test('result keywords stay out of key and field position', () => {
    const src = grammar.repository['keywords-result'].patterns[0].match;
    const re = new RegExp(src);
    assert.ok(re.test('return ok 200 x'), 'route ok must still match');
    assert.ok(re.test('err("m", 1)'), 'expression err must still match');
    assert.ok(!re.test('flags.ok'), 'field access must not match');
    assert.ok(!re.test('ok:'), 'object key must not match');
});

test('snippets are well-formed with unique prefixes', () => {
    const seen = new Set();
    for (const [name, entry] of Object.entries(snippets)) {
        assert.ok(entry.prefix, name + ': no prefix');
        assert.ok(entry.body, name + ': no body');
        assert.ok(entry.description, name + ': no description');
        assert.ok(
            typeof entry.body === 'string' || Array.isArray(entry.body),
            name + ': body must be a string or an array'
        );
        const prefixes = Array.isArray(entry.prefix) ? entry.prefix : [entry.prefix];
        for (const prefix of prefixes) {
            assert.ok(!seen.has(prefix), 'duplicate prefix: ' + prefix);
            seen.add(prefix);
        }
    }
});

test('snippets teach nothing removed', () => {
    const src = JSON.stringify(snippets);
    for (const banned of ['Option<', 'readLine', 'println', 'eprint', 'socket']) {
        assert.ok(!src.includes(banned), 'snippet teaches removed feature: ' + banned);
    }
    assert.ok(!/\bnull\b/.test(src), 'snippet teaches null literal');
});

if (failures > 0) {
    console.log('\n' + failures + ' failing');
    process.exit(1);
}
console.log('\nall passing');
