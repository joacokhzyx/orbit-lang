use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::thread;

const RESP: &[u8] = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nOK";

fn handle(mut stream: TcpStream) {
    let mut buf = [0u8; 16384];
    loop {
        match stream.read(&mut buf) {
            Ok(0) | Err(_) => return,
            Ok(_) => {
                if stream.write_all(RESP).is_err() || stream.flush().is_err() {
                    return;
                }
            }
        }
    }
}

fn main() {
    let listener = TcpListener::bind("127.0.0.1:4103").unwrap();
    for stream in listener.incoming() {
        if let Ok(s) = stream {
            thread::spawn(move || handle(s));
        }
    }
}