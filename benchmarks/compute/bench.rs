use std::env;
use std::time::Instant;

fn fib_recursive(n: u64) -> u64 {
    if n <= 1 {
        return n;
    }
    fib_recursive(n - 1) + fib_recursive(n - 2)
}

fn fib_iterative(n: u64) -> u64 {
    const MOD: u64 = 1_000_000_007;
    if n <= 1 {
        return n;
    }
    let (mut a, mut b) = (0u64, 1u64);
    for _ in 2..=n {
        let tmp = (a + b) % MOD;
        a = b;
        b = tmp;
    }
    b
}

fn sieve(n: usize) -> u64 {
    let mut composite = vec![false; n + 1];
    let mut count = 0u64;
    let mut i = 2;
    while i <= n {
        if !composite[i] {
            count += 1;
            let mut j = i * 2;
            while j <= n {
                composite[j] = true;
                j += i;
            }
        }
        i += 1;
    }
    count
}

fn sum_loop(n: u64) -> u64 {
    let mut s = 0u64;
    for i in 1..=n {
        s += i;
    }
    s
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: bench <test_name> <N>");
        std::process::exit(1);
    }
    let test = &args[1];
    let n: u64 = args[2].parse().expect("invalid N");

    let start = Instant::now();
    let result: u64 = match test.as_str() {
        "fib_recursive" => fib_recursive(n),
        "fib_iterative" => fib_iterative(n),
        "sieve"         => sieve(n as usize),
        "sum"           => sum_loop(n),
        _ => {
            eprintln!("unknown test: {}", test);
            std::process::exit(1);
        }
    };
    let elapsed = start.elapsed().as_nanos();

    println!("time_ns: {}", elapsed);
    println!("result: {}", result);
}
