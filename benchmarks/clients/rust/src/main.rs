use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

#[derive(Clone)]
struct Config {
    url: String,
    duration_seconds: u64,
    concurrency: usize,
    timeout_ms: u64,
    out_path: String,
}

#[derive(Clone)]
struct ParsedUrl {
    host: String,
    port: u16,
    path: String,
}

struct WorkerResult {
    latencies_us: Vec<u64>,
    success: u64,
    errors: u64,
}

fn parse_arg(args: &[String], name: &str, default: &str) -> String {
    let mut i = 1usize;
    while i + 1 < args.len() {
        if args[i] == name {
            return args[i + 1].clone();
        }
        i += 1;
    }
    default.to_string()
}

fn parse_http_url(url: &str) -> Result<ParsedUrl, String> {
    let prefix = "http://";
    if !url.starts_with(prefix) {
        return Err("only http:// URLs are supported".to_string());
    }

    let remainder = &url[prefix.len()..];
    if remainder.is_empty() {
        return Err("URL host is missing".to_string());
    }

    let (host_port, path) = match remainder.find('/') {
        Some(idx) => (&remainder[..idx], &remainder[idx..]),
        None => (remainder, "/"),
    };

    if host_port.is_empty() {
        return Err("URL host is missing".to_string());
    }

    let (host, port) = match host_port.rfind(':') {
        Some(idx) => {
            let host = &host_port[..idx];
            let port = host_port[idx + 1..]
                .parse::<u16>()
                .map_err(|_| "invalid URL port".to_string())?;
            (host.to_string(), port)
        }
        None => (host_port.to_string(), 80),
    };

    if host.is_empty() {
        return Err("URL host is missing".to_string());
    }

    Ok(ParsedUrl {
        host,
        port,
        path: path.to_string(),
    })
}

fn send_http_get(endpoint: &ParsedUrl, timeout: Duration) -> Result<u16, String> {
    let destination = format!("{}:{}", endpoint.host, endpoint.port);
    let mut addresses = destination
        .to_socket_addrs()
        .map_err(|e| format!("DNS error: {e}"))?;

    let addr = addresses
        .next()
        .ok_or_else(|| "no destination address resolved".to_string())?;

    let mut stream = TcpStream::connect_timeout(&addr, timeout)
        .map_err(|e| format!("connect error: {e}"))?;

    stream
        .set_read_timeout(Some(timeout))
        .map_err(|e| format!("set read timeout error: {e}"))?;
    stream
        .set_write_timeout(Some(timeout))
        .map_err(|e| format!("set write timeout error: {e}"))?;

    let request = format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nUser-Agent: orbit-bench-rust\r\nConnection: close\r\nAccept: */*\r\n\r\n",
        endpoint.path, endpoint.host
    );

    stream
        .write_all(request.as_bytes())
        .map_err(|e| format!("send error: {e}"))?;
    stream.flush().map_err(|e| format!("flush error: {e}"))?;

    let mut reader = BufReader::new(stream);
    let mut status_line = String::new();
    reader
        .read_line(&mut status_line)
        .map_err(|e| format!("read status line error: {e}"))?;

    let status_code = status_line
        .split_whitespace()
        .nth(1)
        .ok_or_else(|| "invalid HTTP status line".to_string())?
        .parse::<u16>()
        .map_err(|_| "invalid HTTP status code".to_string())?;

    let mut sink = Vec::new();
    let _ = reader.read_to_end(&mut sink);

    Ok(status_code)
}

fn run_worker(endpoint: Arc<ParsedUrl>, deadline: Instant, timeout: Duration) -> WorkerResult {
    let mut latencies_us: Vec<u64> = Vec::new();
    let mut success = 0u64;
    let mut errors = 0u64;

    while Instant::now() < deadline {
        let started = Instant::now();
        let result = send_http_get(&endpoint, timeout);
        let latency_us = started.elapsed().as_micros() as u64;
        latencies_us.push(latency_us);

        match result {
            Ok(status) if (200..400).contains(&status) => success += 1,
            _ => errors += 1,
        }
    }

    WorkerResult {
        latencies_us,
        success,
        errors,
    }
}

fn percentile(sorted_latencies: &[u64], percentile: f64) -> u64 {
    if sorted_latencies.is_empty() {
        return 0;
    }

    let raw_index = (percentile * (sorted_latencies.len() - 1) as f64).round() as usize;
    sorted_latencies[raw_index.min(sorted_latencies.len() - 1)]
}

fn main() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();

    let cfg = Config {
        url: parse_arg(&args, "--url", "http://127.0.0.1:3000/health"),
        duration_seconds: parse_arg(&args, "--duration-seconds", "10")
            .parse::<u64>()
            .map_err(|_| "invalid --duration-seconds".to_string())?,
        concurrency: parse_arg(&args, "--concurrency", "16")
            .parse::<usize>()
            .map_err(|_| "invalid --concurrency".to_string())?,
        timeout_ms: parse_arg(&args, "--timeout-ms", "3000")
            .parse::<u64>()
            .map_err(|_| "invalid --timeout-ms".to_string())?,
        out_path: parse_arg(&args, "--out", "rust-benchmark.json"),
    };

    if cfg.concurrency == 0 {
        return Err("--concurrency must be greater than zero".to_string());
    }

    let endpoint = Arc::new(parse_http_url(&cfg.url)?);
    let timeout = Duration::from_millis(cfg.timeout_ms);

    let wall_started = Instant::now();
    let deadline = wall_started + Duration::from_secs(cfg.duration_seconds);

    let mut handles = Vec::with_capacity(cfg.concurrency);
    for _ in 0..cfg.concurrency {
        let endpoint_clone = Arc::clone(&endpoint);
        handles.push(thread::spawn(move || run_worker(endpoint_clone, deadline, timeout)));
    }

    let mut all_latencies: Vec<u64> = Vec::new();
    let mut success_total = 0u64;
    let mut error_total = 0u64;

    for handle in handles {
        let worker = handle
            .join()
            .map_err(|_| "worker thread panicked".to_string())?;
        all_latencies.extend(worker.latencies_us);
        success_total += worker.success;
        error_total += worker.errors;
    }

    let elapsed_seconds = wall_started.elapsed().as_secs_f64().max(0.0001);
    let requests_total = success_total + error_total;

    all_latencies.sort_unstable();

    let latency_min_us = all_latencies.first().copied().unwrap_or(0);
    let latency_max_us = all_latencies.last().copied().unwrap_or(0);
    let latency_p50_us = percentile(&all_latencies, 0.50);
    let latency_p90_us = percentile(&all_latencies, 0.90);
    let latency_p99_us = percentile(&all_latencies, 0.99);

    let latency_sum_us: u128 = all_latencies.iter().map(|&v| v as u128).sum();
    let latency_mean_us = if requests_total == 0 {
        0.0
    } else {
        latency_sum_us as f64 / requests_total as f64
    };

    let throughput_rps = requests_total as f64 / elapsed_seconds;
    let error_rate_pct = if requests_total == 0 {
        0.0
    } else {
        (error_total as f64 * 100.0) / requests_total as f64
    };

    let output_json = format!(
        "{{\n  \"runner\": \"rust\",\n  \"url\": \"{}\",\n  \"duration_seconds\": {},\n  \"concurrency\": {},\n  \"requests_total\": {},\n  \"success_total\": {},\n  \"error_total\": {},\n  \"error_rate_pct\": {:.6},\n  \"throughput_rps\": {:.6},\n  \"latency_ms\": {{\n    \"min\": {:.6},\n    \"p50\": {:.6},\n    \"p90\": {:.6},\n    \"p99\": {:.6},\n    \"max\": {:.6},\n    \"mean\": {:.6}\n  }}\n}}\n",
        cfg.url,
        cfg.duration_seconds,
        cfg.concurrency,
        requests_total,
        success_total,
        error_total,
        error_rate_pct,
        throughput_rps,
        latency_min_us as f64 / 1000.0,
        latency_p50_us as f64 / 1000.0,
        latency_p90_us as f64 / 1000.0,
        latency_p99_us as f64 / 1000.0,
        latency_max_us as f64 / 1000.0,
        latency_mean_us / 1000.0
    );

    fs::write(&cfg.out_path, output_json)
        .map_err(|e| format!("failed writing output file: {e}"))?;

    println!(
        "[rust] c={} req={} ok={} err={} rps={:.2} p99={:.3}ms out={}",
        cfg.concurrency,
        requests_total,
        success_total,
        error_total,
        throughput_rps,
        latency_p99_us as f64 / 1000.0,
        cfg.out_path
    );

    Ok(())
}
