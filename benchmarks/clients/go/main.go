package main

import (
    "encoding/json"
    "flag"
    "fmt"
    "io"
    "net/http"
    "os"
    "sort"
    "sync"
    "time"
)

type workerResult struct {
    LatenciesUs []int64
    Success     uint64
    Errors      uint64
}

type latencyMetrics struct {
    Min  float64 `json:"min"`
    P50  float64 `json:"p50"`
    P90  float64 `json:"p90"`
    P99  float64 `json:"p99"`
    Max  float64 `json:"max"`
    Mean float64 `json:"mean"`
}

type benchmarkResult struct {
    Runner        string         `json:"runner"`
    URL           string         `json:"url"`
    DurationSec   int            `json:"duration_seconds"`
    Concurrency   int            `json:"concurrency"`
    RequestsTotal uint64         `json:"requests_total"`
    SuccessTotal  uint64         `json:"success_total"`
    ErrorTotal    uint64         `json:"error_total"`
    ErrorRatePct  float64        `json:"error_rate_pct"`
    ThroughputRPS float64        `json:"throughput_rps"`
    LatencyMs     latencyMetrics `json:"latency_ms"`
}

func percentile(values []int64, p float64) int64 {
    if len(values) == 0 {
        return 0
    }
    idx := int((p * float64(len(values)-1)) + 0.5)
    if idx < 0 {
        idx = 0
    }
    if idx >= len(values) {
        idx = len(values) - 1
    }
    return values[idx]
}

func runWorker(client *http.Client, targetURL string, deadline time.Time) workerResult {
    result := workerResult{
        LatenciesUs: make([]int64, 0, 1024),
    }

    for time.Now().Before(deadline) {
        started := time.Now()
        response, err := client.Get(targetURL)
        elapsedUs := time.Since(started).Microseconds()
        result.LatenciesUs = append(result.LatenciesUs, elapsedUs)

        if err != nil {
            result.Errors++
            continue
        }

        io.Copy(io.Discard, response.Body)
        response.Body.Close()

        if response.StatusCode >= 200 && response.StatusCode < 400 {
            result.Success++
        } else {
            result.Errors++
        }
    }

    return result
}

func main() {
    url := flag.String("url", "http://127.0.0.1:3000/health", "benchmark target URL")
    durationSeconds := flag.Int("duration-seconds", 10, "benchmark duration per run in seconds")
    concurrency := flag.Int("concurrency", 16, "number of concurrent workers")
    timeoutMs := flag.Int("timeout-ms", 3000, "HTTP timeout in milliseconds")
    outPath := flag.String("out", "go-benchmark.json", "output JSON path")
    flag.Parse()

    if *concurrency <= 0 {
        fmt.Fprintln(os.Stderr, "--concurrency must be greater than zero")
        os.Exit(1)
    }

    transport := &http.Transport{
        DisableKeepAlives:   true,
        MaxIdleConns:        0,
        MaxIdleConnsPerHost: 0,
    }

    client := &http.Client{
        Timeout:   time.Duration(*timeoutMs) * time.Millisecond,
        Transport: transport,
    }

    started := time.Now()
    deadline := started.Add(time.Duration(*durationSeconds) * time.Second)

    results := make([]workerResult, *concurrency)
    var wg sync.WaitGroup
    wg.Add(*concurrency)

    for i := 0; i < *concurrency; i++ {
        idx := i
        go func() {
            defer wg.Done()
            results[idx] = runWorker(client, *url, deadline)
        }()
    }

    wg.Wait()

    var allLatencies []int64
    var successTotal uint64
    var errorTotal uint64

    for _, worker := range results {
        allLatencies = append(allLatencies, worker.LatenciesUs...)
        successTotal += worker.Success
        errorTotal += worker.Errors
    }

    requestsTotal := successTotal + errorTotal
    elapsedSeconds := time.Since(started).Seconds()
    if elapsedSeconds <= 0 {
        elapsedSeconds = 0.0001
    }

    sort.Slice(allLatencies, func(i, j int) bool {
        return allLatencies[i] < allLatencies[j]
    })

    minUs := int64(0)
    maxUs := int64(0)
    p50Us := percentile(allLatencies, 0.50)
    p90Us := percentile(allLatencies, 0.90)
    p99Us := percentile(allLatencies, 0.99)

    if len(allLatencies) > 0 {
        minUs = allLatencies[0]
        maxUs = allLatencies[len(allLatencies)-1]
    }

    var totalUs int64
    for _, v := range allLatencies {
        totalUs += v
    }

    meanUs := 0.0
    if requestsTotal > 0 {
        meanUs = float64(totalUs) / float64(requestsTotal)
    }

    errorRatePct := 0.0
    if requestsTotal > 0 {
        errorRatePct = (float64(errorTotal) * 100.0) / float64(requestsTotal)
    }

    throughputRps := float64(requestsTotal) / elapsedSeconds

    summary := benchmarkResult{
        Runner:        "go",
        URL:           *url,
        DurationSec:   *durationSeconds,
        Concurrency:   *concurrency,
        RequestsTotal: requestsTotal,
        SuccessTotal:  successTotal,
        ErrorTotal:    errorTotal,
        ErrorRatePct:  errorRatePct,
        ThroughputRPS: throughputRps,
        LatencyMs: latencyMetrics{
            Min:  float64(minUs) / 1000.0,
            P50:  float64(p50Us) / 1000.0,
            P90:  float64(p90Us) / 1000.0,
            P99:  float64(p99Us) / 1000.0,
            Max:  float64(maxUs) / 1000.0,
            Mean: meanUs / 1000.0,
        },
    }

    payload, err := json.MarshalIndent(summary, "", "  ")
    if err != nil {
        fmt.Fprintf(os.Stderr, "failed to encode JSON: %v\n", err)
        os.Exit(1)
    }

    if err := os.WriteFile(*outPath, append(payload, '\n'), 0o644); err != nil {
        fmt.Fprintf(os.Stderr, "failed to write output: %v\n", err)
        os.Exit(1)
    }

    fmt.Printf("[go] c=%d req=%d ok=%d err=%d rps=%.2f p99=%.3fms out=%s\n",
        *concurrency,
        requestsTotal,
        successTotal,
        errorTotal,
        throughputRps,
        float64(p99Us)/1000.0,
        *outPath,
    )
}
