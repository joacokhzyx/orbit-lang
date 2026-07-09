#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <numeric>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#endif

struct UrlParts {
    std::string host;
    int port;
    std::string path;
};

struct WorkerResult {
    std::vector<uint64_t> latencies_us;
    uint64_t success = 0;
    uint64_t errors = 0;
};

#ifdef _WIN32
using SocketHandle = SOCKET;
constexpr SocketHandle kInvalidSocket = INVALID_SOCKET;
#else
using SocketHandle = int;
constexpr SocketHandle kInvalidSocket = -1;
#endif

static void close_socket(SocketHandle socket_handle) {
#ifdef _WIN32
    closesocket(socket_handle);
#else
    close(socket_handle);
#endif
}

static bool parse_http_url(const std::string &url, UrlParts &parts) {
    const std::string prefix = "http://";
    if (url.rfind(prefix, 0) != 0) {
        return false;
    }

    std::string remainder = url.substr(prefix.size());
    if (remainder.empty()) {
        return false;
    }

    std::string host_port;
    size_t slash_pos = remainder.find('/');
    if (slash_pos == std::string::npos) {
        host_port = remainder;
        parts.path = "/";
    } else {
        host_port = remainder.substr(0, slash_pos);
        parts.path = remainder.substr(slash_pos);
    }

    if (host_port.empty()) {
        return false;
    }

    size_t colon_pos = host_port.rfind(':');
    if (colon_pos == std::string::npos) {
        parts.host = host_port;
        parts.port = 80;
    } else {
        parts.host = host_port.substr(0, colon_pos);
        std::string port_text = host_port.substr(colon_pos + 1);
        if (parts.host.empty() || port_text.empty()) {
            return false;
        }
        parts.port = std::atoi(port_text.c_str());
        if (parts.port <= 0 || parts.port > 65535) {
            return false;
        }
    }

    return !parts.host.empty();
}

static bool send_http_get(const UrlParts &url, int timeout_ms, int &status_code) {
    status_code = 0;

    struct addrinfo hints;
    std::memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    struct addrinfo *resolved = nullptr;
    const std::string port_text = std::to_string(url.port);

    if (getaddrinfo(url.host.c_str(), port_text.c_str(), &hints, &resolved) != 0) {
        return false;
    }

    SocketHandle sock = kInvalidSocket;

    for (struct addrinfo *it = resolved; it != nullptr; it = it->ai_next) {
        sock = socket(it->ai_family, it->ai_socktype, it->ai_protocol);
        if (sock == kInvalidSocket) {
            continue;
        }

#ifdef _WIN32
        DWORD timeout = static_cast<DWORD>(timeout_ms);
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char *>(&timeout), sizeof(timeout));
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char *>(&timeout), sizeof(timeout));
#else
        struct timeval timeout;
        timeout.tv_sec = timeout_ms / 1000;
        timeout.tv_usec = (timeout_ms % 1000) * 1000;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
#endif

        if (connect(sock, it->ai_addr, static_cast<int>(it->ai_addrlen)) == 0) {
            break;
        }

        close_socket(sock);
        sock = kInvalidSocket;
    }

    freeaddrinfo(resolved);

    if (sock == kInvalidSocket) {
        return false;
    }

    std::ostringstream request_builder;
    request_builder
        << "GET " << url.path << " HTTP/1.1\r\n"
        << "Host: " << url.host << "\r\n"
        << "User-Agent: orbit-bench-cpp\r\n"
        << "Connection: close\r\n"
        << "Accept: */*\r\n\r\n";

    const std::string request = request_builder.str();
    const char *payload = request.c_str();
    size_t total_sent = 0;

    while (total_sent < request.size()) {
#ifdef _WIN32
        int sent = send(sock, payload + total_sent, static_cast<int>(request.size() - total_sent), 0);
#else
        ssize_t sent = send(sock, payload + total_sent, request.size() - total_sent, 0);
#endif
        if (sent <= 0) {
            close_socket(sock);
            return false;
        }
        total_sent += static_cast<size_t>(sent);
    }

    char response[2048];
#ifdef _WIN32
    int received = recv(sock, response, sizeof(response) - 1, 0);
#else
    ssize_t received = recv(sock, response, sizeof(response) - 1, 0);
#endif

    close_socket(sock);

    if (received <= 0) {
        return false;
    }

    response[received] = '\0';
    std::string head(response);
    size_t line_end = head.find("\r\n");
    if (line_end != std::string::npos) {
        head = head.substr(0, line_end);
    }

    std::istringstream parser(head);
    std::string protocol;
    parser >> protocol >> status_code;

    return status_code > 0;
}

static uint64_t percentile(const std::vector<uint64_t> &sorted_values, double p) {
    if (sorted_values.empty()) {
        return 0;
    }

    size_t idx = static_cast<size_t>(std::llround(p * static_cast<double>(sorted_values.size() - 1)));
    if (idx >= sorted_values.size()) {
        idx = sorted_values.size() - 1;
    }

    return sorted_values[idx];
}

static WorkerResult run_worker(const UrlParts &url, std::chrono::steady_clock::time_point deadline, int timeout_ms) {
    WorkerResult result;
    result.latencies_us.reserve(4096);

    while (std::chrono::steady_clock::now() < deadline) {
        auto started = std::chrono::steady_clock::now();
        int status = 0;
        bool ok = send_http_get(url, timeout_ms, status);
        auto elapsed_us = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - started).count());

        result.latencies_us.push_back(elapsed_us);

        if (ok && status >= 200 && status < 400) {
            result.success++;
        } else {
            result.errors++;
        }
    }

    return result;
}

int main(int argc, char **argv) {
#ifdef _WIN32
    WSADATA wsa_data;
    if (WSAStartup(MAKEWORD(2, 2), &wsa_data) != 0) {
        std::cerr << "failed to initialize Winsock" << std::endl;
        return 1;
    }
#endif

    std::map<std::string, std::string> options;
    for (int i = 1; i + 1 < argc; ++i) {
        std::string key(argv[i]);
        if (key.rfind("--", 0) == 0) {
            options[key] = argv[i + 1];
            ++i;
        }
    }

    const std::string url_text = options.count("--url") ? options["--url"] : "http://127.0.0.1:3000/health";
    const int duration_seconds = options.count("--duration-seconds") ? std::atoi(options["--duration-seconds"].c_str()) : 10;
    const int concurrency = options.count("--concurrency") ? std::atoi(options["--concurrency"].c_str()) : 16;
    const int timeout_ms = options.count("--timeout-ms") ? std::atoi(options["--timeout-ms"].c_str()) : 3000;
    const std::string out_path = options.count("--out") ? options["--out"] : "cpp-benchmark.json";

    if (concurrency <= 0 || duration_seconds <= 0 || timeout_ms <= 0) {
        std::cerr << "invalid arguments: duration/concurrency/timeout must be > 0" << std::endl;
#ifdef _WIN32
        WSACleanup();
#endif
        return 1;
    }

    UrlParts url;
    if (!parse_http_url(url_text, url)) {
        std::cerr << "invalid URL, expected http://host:port/path" << std::endl;
#ifdef _WIN32
        WSACleanup();
#endif
        return 1;
    }

    std::vector<WorkerResult> workers(static_cast<size_t>(concurrency));
    std::vector<std::thread> threads;
    threads.reserve(static_cast<size_t>(concurrency));

    auto started = std::chrono::steady_clock::now();
    auto deadline = started + std::chrono::seconds(duration_seconds);

    for (int i = 0; i < concurrency; ++i) {
        threads.emplace_back([&, i]() {
            workers[static_cast<size_t>(i)] = run_worker(url, deadline, timeout_ms);
        });
    }

    for (auto &thread : threads) {
        thread.join();
    }

    std::vector<uint64_t> all_latencies;
    uint64_t success_total = 0;
    uint64_t error_total = 0;

    for (const auto &worker : workers) {
        all_latencies.insert(all_latencies.end(), worker.latencies_us.begin(), worker.latencies_us.end());
        success_total += worker.success;
        error_total += worker.errors;
    }

    const uint64_t requests_total = success_total + error_total;
    double elapsed_seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
    if (elapsed_seconds <= 0.0) {
        elapsed_seconds = 0.0001;
    }

    std::sort(all_latencies.begin(), all_latencies.end());

    const uint64_t min_us = all_latencies.empty() ? 0 : all_latencies.front();
    const uint64_t max_us = all_latencies.empty() ? 0 : all_latencies.back();
    const uint64_t p50_us = percentile(all_latencies, 0.50);
    const uint64_t p90_us = percentile(all_latencies, 0.90);
    const uint64_t p99_us = percentile(all_latencies, 0.99);

    const unsigned long long sum_us = std::accumulate(
        all_latencies.begin(),
        all_latencies.end(),
        0ULL,
        [](unsigned long long acc, uint64_t value) {
            return acc + value;
        });

    const double mean_us = requests_total == 0 ? 0.0 : static_cast<double>(sum_us) / static_cast<double>(requests_total);
    const double throughput_rps = static_cast<double>(requests_total) / elapsed_seconds;
    const double error_rate_pct = requests_total == 0
                                      ? 0.0
                                      : (static_cast<double>(error_total) * 100.0) / static_cast<double>(requests_total);

    std::ofstream output(out_path, std::ios::out | std::ios::trunc);
    if (!output.is_open()) {
        std::cerr << "failed to open output file: " << out_path << std::endl;
#ifdef _WIN32
        WSACleanup();
#endif
        return 1;
    }

    output << std::fixed << std::setprecision(6);
    output << "{\n";
    output << "  \"runner\": \"cpp\",\n";
    output << "  \"url\": \"" << url_text << "\",\n";
    output << "  \"duration_seconds\": " << duration_seconds << ",\n";
    output << "  \"concurrency\": " << concurrency << ",\n";
    output << "  \"requests_total\": " << requests_total << ",\n";
    output << "  \"success_total\": " << success_total << ",\n";
    output << "  \"error_total\": " << error_total << ",\n";
    output << "  \"error_rate_pct\": " << error_rate_pct << ",\n";
    output << "  \"throughput_rps\": " << throughput_rps << ",\n";
    output << "  \"latency_ms\": {\n";
    output << "    \"min\": " << static_cast<double>(min_us) / 1000.0 << ",\n";
    output << "    \"p50\": " << static_cast<double>(p50_us) / 1000.0 << ",\n";
    output << "    \"p90\": " << static_cast<double>(p90_us) / 1000.0 << ",\n";
    output << "    \"p99\": " << static_cast<double>(p99_us) / 1000.0 << ",\n";
    output << "    \"max\": " << static_cast<double>(max_us) / 1000.0 << ",\n";
    output << "    \"mean\": " << mean_us / 1000.0 << "\n";
    output << "  }\n";
    output << "}\n";
    output.close();

    std::cout << "[cpp] c=" << concurrency
              << " req=" << requests_total
              << " ok=" << success_total
              << " err=" << error_total
              << " rps=" << std::setprecision(2) << throughput_rps
              << " p99=" << std::setprecision(3) << static_cast<double>(p99_us) / 1000.0 << "ms"
              << " out=" << out_path << std::endl;

#ifdef _WIN32
    WSACleanup();
#endif
    return 0;
}
