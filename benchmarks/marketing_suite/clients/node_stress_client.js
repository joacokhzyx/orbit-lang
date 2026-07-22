const http = require('http');

const url = process.argv[2] || 'http://127.0.0.1:4001/loop';
const durationSec = parseInt(process.argv[3] || '5', 10);
const concurrency = parseInt(process.argv[4] || '100', 10);

const agent = new http.Agent({ keepAlive: true, maxSockets: concurrency });

let success = 0;
let errors = 0;
const stopTime = Date.now() + durationSec * 1000;

function sendRequest() {
    if (Date.now() >= stopTime) return;
    const req = http.get(url, { agent }, (res) => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
            success++;
        } else {
            errors++;
        }
        res.resume();
        setImmediate(sendRequest);
    });
    req.on('error', () => {
        errors++;
        setImmediate(sendRequest);
    });
}

for (let i = 0; i < concurrency; i++) {
    sendRequest();
}

setTimeout(() => {
    const total = success + errors;
    const rps = (total / durationSec).toFixed(1);
    console.log(JSON.stringify({ client: "Node.js", total, success, errors, rps: parseFloat(rps) }));
    process.exit(0);
}, durationSec * 1000 + 200);
