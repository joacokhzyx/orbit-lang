use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use std::convert::Infallible;
use std::net::SocketAddr;
use tokio::net::TcpListener;
use tokio::signal;

const MOD: u64 = 1_000_000_007;

fn fib(n: i64) -> u64 {
    if n < 0 {
        return 0;
    }
    let n = if n > 1_000_000 { 1_000_000 } else { n as usize };
    if n == 0 {
        return 0;
    }
    if n == 1 {
        return 1;
    }
    let (mut a, mut b) = (0u64, 1u64);
    for _ in 2..=n {
        let c = (a + b) % MOD;
        a = b;
        b = c;
    }
    b
}

fn parse_query_n(query: Option<&str>) -> Option<i64> {
    let q = query?;
    for part in q.split('&') {
        if let Some(val) = part.strip_prefix("n=") {
            return val.parse::<i64>().ok();
        }
    }
    None
}

async fn handle(req: Request<hyper::body::Incoming>) -> Result<Response<Full<Bytes>>, Infallible> {
    let path = req.uri().path();
    let query = req.uri().query();

    if req.method() != Method::GET {
        return Ok(Response::builder()
            .status(StatusCode::NOT_FOUND)
            .header("Content-Type", "text/plain")
            .body(Full::new(Bytes::from("Not Found\n")))
            .unwrap());
    }

    match path {
        "/" => {
            let body = Bytes::from("OK\n");
            Ok(Response::builder()
                .status(StatusCode::OK)
                .header("Content-Type", "text/plain")
                .header("Content-Length", "3")
                .body(Full::new(body))
                .unwrap())
        }
        "/fib" => {
            if let Some(n) = parse_query_n(query) {
                let result = fib(n);
                let body = format!("{}\n", result);
                let len = body.len();
                Ok(Response::builder()
                    .status(StatusCode::OK)
                    .header("Content-Type", "text/plain")
                    .header("Content-Length", len.to_string())
                    .body(Full::new(Bytes::from(body)))
                    .unwrap())
            } else {
                Ok(Response::builder()
                    .status(StatusCode::NOT_FOUND)
                    .header("Content-Type", "text/plain")
                    .body(Full::new(Bytes::from("Not Found\n")))
                    .unwrap())
            }
        }
        _ => Ok(Response::builder()
            .status(StatusCode::NOT_FOUND)
            .header("Content-Type", "text/plain")
            .body(Full::new(Bytes::from("Not Found\n")))
            .unwrap()),
    }
}

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        std::process::exit(1);
    }
    let port: u16 = args[1].parse().unwrap_or_else(|_| std::process::exit(1));
    let addr = SocketAddr::from(([0, 0, 0, 0], port));

    let listener = TcpListener::bind(addr).await.unwrap_or_else(|_| std::process::exit(1));

    let shutdown = async {
        signal::ctrl_c().await.ok();
    };
    tokio::pin!(shutdown);

    loop {
        tokio::select! {
            result = listener.accept() => {
                let (stream, _) = match result {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                let io = TokioIo::new(stream);
                tokio::spawn(async move {
                    let _ = http1::Builder::new()
                        .keep_alive(true)
                        .serve_connection(io, service_fn(handle))
                        .await;
                });
            }
            _ = &mut shutdown => {
                break;
            }
        }
    }
}
