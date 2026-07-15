'use strict';

const http = require('http');
const url  = require('url');

const MOD = 1_000_000_007n;

function fib(n) {
  if (n < 0) return 0n;
  if (n > 1_000_000) n = 1_000_000;
  if (n === 0) return 0n;
  if (n === 1) return 1n;
  let a = 0n, b = 1n;
  for (let i = 2; i <= n; i++) {
    const c = (a + b) % MOD;
    a = b;
    b = c;
  }
  return b;
}

const args = process.argv.slice(2);
if (args.length < 1) process.exit(1);
const port = parseInt(args[0], 10);
if (!port) process.exit(1);

const server = http.createServer((req, res) => {
  const parsed = url.parse(req.url, true);
  const pathname = parsed.pathname;

  if (req.method !== 'GET') {
    const body = 'Not Found\n';
    res.writeHead(404, {
      'Content-Type': 'text/plain',
      'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
    return;
  }

  if (pathname === '/') {
    res.writeHead(200, {
      'Content-Type': 'text/plain',
      'Content-Length': 3,
    });
    res.end('OK\n');
    return;
  }

  if (pathname === '/fib') {
    const nStr = parsed.query.n;
    const n = parseInt(nStr, 10);
    if (nStr === undefined || nStr === null || isNaN(n)) {
      const body = 'Not Found\n';
      res.writeHead(404, {
        'Content-Type': 'text/plain',
        'Content-Length': Buffer.byteLength(body),
      });
      res.end(body);
      return;
    }
    const result = fib(n).toString() + '\n';
    res.writeHead(200, {
      'Content-Type': 'text/plain',
      'Content-Length': Buffer.byteLength(result),
    });
    res.end(result);
    return;
  }

  const body = 'Not Found\n';
  res.writeHead(404, {
    'Content-Type': 'text/plain',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
});

server.listen(port, '0.0.0.0', () => {
  // Silent after bind — no output
});

process.on('SIGTERM', () => { server.close(); process.exit(0); });
process.on('SIGINT',  () => { server.close(); process.exit(0); });
