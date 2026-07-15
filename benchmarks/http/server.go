package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
)

const mod = 1_000_000_007

func fib(n int) int {
	if n < 0 {
		return 0
	}
	if n > 1_000_000 {
		n = 1_000_000
	}
	if n == 0 {
		return 0
	}
	if n == 1 {
		return 1
	}
	a, b := 0, 1
	for i := 2; i <= n; i++ {
		a, b = b, (a+b)%mod
	}
	return b
}

func rootHandler(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.Error(w, "Not Found\n", http.StatusNotFound)
		return
	}
	if r.Method != http.MethodGet {
		http.Error(w, "Not Found\n", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "text/plain")
	w.Header().Set("Content-Length", "3")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK\n"))
}

func fibHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Not Found\n", http.StatusNotFound)
		return
	}
	nStr := r.URL.Query().Get("n")
	n, err := strconv.Atoi(nStr)
	if err != nil {
		http.Error(w, "Not Found\n", http.StatusNotFound)
		return
	}
	result := fib(n)
	body := fmt.Sprintf("%d\n", result)
	w.Header().Set("Content-Type", "text/plain")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(body))
}

func notFoundHandler(w http.ResponseWriter, r *http.Request) {
	http.Error(w, "Not Found\n", http.StatusNotFound)
}

func main() {
	if len(os.Args) < 2 {
		os.Exit(1)
	}
	port := os.Args[1]

	mux := http.NewServeMux()
	mux.HandleFunc("/", rootHandler)
	mux.HandleFunc("/fib", fibHandler)

	ln, err := net.Listen("tcp", "0.0.0.0:"+port)
	if err != nil {
		os.Exit(1)
	}

	// Enable SO_REUSEADDR (Go sets it by default on TCP listeners)
	srv := &http.Server{Handler: mux}

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGTERM, syscall.SIGINT)

	go func() {
		<-quit
		ln.Close()
		os.Exit(0)
	}()

	srv.Serve(ln)
}
