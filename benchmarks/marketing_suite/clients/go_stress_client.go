package main

import (
	"fmt"
	"net/http"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	targetURL := "http://127.0.0.1:4001/loop"
	durationSec := 5
	concurrency := 100

	if len(os.Args) > 1 {
		targetURL = os.Args[1]
	}
	if len(os.Args) > 2 {
		durationSec, _ = strconv.Atoi(os.Args[2])
	}
	if len(os.Args) > 3 {
		concurrency, _ = strconv.Atoi(os.Args[3])
	}

	tr := &http.Transport{
		MaxIdleConnsPerHost: concurrency,
		DisableKeepAlives:   false,
	}
	client := &http.Client{Transport: tr, Timeout: 2 * time.Second}

	var success uint64
	var errors uint64
	stop := time.Now().Add(time.Duration(durationSec) * time.Second)

	var wg sync.WaitGroup
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for time.Now().Before(stop) {
				resp, err := client.Get(targetURL)
				if err != nil {
					atomic.AddUint64(&errors, 1)
					continue
				}
				if resp.StatusCode >= 200 && resp.StatusCode < 300 {
					atomic.AddUint64(&success, 1)
				} else {
					atomic.AddUint64(&errors, 1)
				}
				resp.Body.Close()
			}
		}()
	}

	wg.Wait()
	total := success + errors
	rps := float64(total) / float64(durationSec)
	fmt.Printf("{\"client\":\"Go\",\"total\":%d,\"success\":%d,\"errors\":%d,\"rps\":%.1f}\n", total, success, errors, rps)
}
