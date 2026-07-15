'use strict';

function fibRecursive(n) {
    if (n <= 1) return n;
    return fibRecursive(n - 1) + fibRecursive(n - 2);
}

function fibIterative(n) {
    const MOD = 1_000_000_007n;
    if (n <= 1n) return n;
    let a = 0n, b = 1n;
    for (let i = 2n; i <= n; i++) {
        const tmp = (a + b) % MOD;
        a = b;
        b = tmp;
    }
    return b;
}

function sieve(n) {
    const composite = new Uint8Array(n + 1);
    let count = 0;
    for (let i = 2; i <= n; i++) {
        if (!composite[i]) {
            count++;
            for (let j = i * 2; j <= n; j += i) {
                composite[j] = 1;
            }
        }
    }
    return count;
}

function sumLoop(n) {
    let s = 0n;
    for (let i = 1n; i <= n; i++) s += i;
    return s;
}

const args = process.argv;
if (args.length !== 4) {
    process.stderr.write('usage: bench.js <test_name> <N>\n');
    process.exit(1);
}

const test = args[2];
const nRaw = args[3];

let result;
const t0 = process.hrtime.bigint();

switch (test) {
    case 'fib_recursive': {
        const n = parseInt(nRaw, 10);
        result = BigInt(fibRecursive(n));
        break;
    }
    case 'fib_iterative': {
        const n = BigInt(nRaw);
        result = fibIterative(n);
        break;
    }
    case 'sieve': {
        const n = parseInt(nRaw, 10);
        result = BigInt(sieve(n));
        break;
    }
    case 'sum': {
        const n = BigInt(nRaw);
        result = sumLoop(n);
        break;
    }
    default:
        process.stderr.write('unknown test: ' + test + '\n');
        process.exit(1);
}

const elapsed = process.hrtime.bigint() - t0;

process.stdout.write('time_ns: ' + elapsed.toString() + '\n');
process.stdout.write('result: ' + result.toString() + '\n');
