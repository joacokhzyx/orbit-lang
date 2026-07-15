package main

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

func fibRecursive(n int) int {
	if n <= 1 {
		return n
	}
	return fibRecursive(n-1) + fibRecursive(n-2)
}

func fibIterative(n int) int {
	const mod = 1_000_000_007
	if n <= 1 {
		return n
	}
	a, b := 0, 1
	for i := 2; i <= n; i++ {
		a, b = b, (a+b)%mod
	}
	return b
}

func sieve(n int) int {
	composite := make([]bool, n+1)
	count := 0
	for i := 2; i <= n; i++ {
		if !composite[i] {
			count++
			for j := i * 2; j <= n; j += i {
				composite[j] = true
			}
		}
	}
	return count
}

func sumLoop(n int) int {
	s := 0
	for i := 1; i <= n; i++ {
		s += i
	}
	return s
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: bench <test_name> <N>")
		os.Exit(1)
	}
	test := os.Args[1]
	n, err := strconv.Atoi(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, "invalid N:", err)
		os.Exit(1)
	}

	var result int
	start := time.Now()
	switch test {
	case "fib_recursive":
		result = fibRecursive(n)
	case "fib_iterative":
		result = fibIterative(n)
	case "sieve":
		result = sieve(n)
	case "sum":
		result = sumLoop(n)
	default:
		fmt.Fprintln(os.Stderr, "unknown test:", test)
		os.Exit(1)
	}
	elapsed := time.Since(start)

	fmt.Printf("time_ns: %d\n", elapsed.Nanoseconds())
	fmt.Printf("result: %d\n", result)
}
