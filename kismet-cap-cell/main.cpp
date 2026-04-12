#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#include <chrono>
#include <csignal>
#include <cstring>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

static volatile std::sig_atomic_t g_stop = 0;

struct Args {
    std::string socket_path = "/var/run/kismet/cell.sock";
    bool enable_tcp = false;
    int tcp_port = 8765;  // Matches phone/collector default
    bool list_only = false;
};

void usage(const char* prog) {
    std::cerr << "Usage: " << prog
              << " [--socket /path/to.sock] [--enable-tcp --tcp-port N] [--list]\n";
}

Args parse_args(int argc, char* argv[]) {
    Args args;
    for (int i = 1; i < argc; ++i) {
        std::string a(argv[i]);
        if (a == "--socket" && i + 1 < argc) {
            args.socket_path = argv[++i];
        } else if (a == "--enable-tcp") {
            args.enable_tcp = true;
        } else if (a == "--tcp-port" && i + 1 < argc) {
            args.tcp_port = std::stoi(argv[++i]);
        } else if (a == "--list") {
            args.list_only = true;
        } else if (a == "-h" || a == "--help") {
            usage(argv[0]);
            std::exit(0);
        } else {
            usage(argv[0]);
            std::exit(1);
        }
    }
    return args;
}

void handle_client(int fd, const std::string& tag) {
    std::string buf;
    buf.reserve(4096);
    char tmp[1024];
    while (!g_stop) {
        ssize_t n = read(fd, tmp, sizeof(tmp));
        if (n <= 0) break;
        buf.append(tmp, tmp + n);
        std::size_t pos;
        while ((pos = buf.find('\n')) != std::string::npos) {
            std::string line = buf.substr(0, pos);
            buf.erase(0, pos + 1);
            std::cout << "[" << tag << "] " << line << std::endl;
        }
    }
    close(fd);
    std::cout << "[" << tag << "] disconnected" << std::endl;
}

int create_uds_listener(const std::string& path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("socket(AF_UNIX)");
        return -1;
    }
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (path.size() >= sizeof(addr.sun_path)) {
        std::cerr << "Socket path too long\n";
        close(fd);
        return -1;
    }
    std::strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);
    unlink(path.c_str());
    if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        perror("bind(uds)");
        close(fd);
        return -1;
    }
    if (listen(fd, 8) < 0) {
        perror("listen(uds)");
        close(fd);
        return -1;
    }
    return fd;
}

int create_tcp_listener(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("socket(AF_INET)");
        return -1;
    }
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);
    if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        perror("bind(tcp)");
        close(fd);
        return -1;
    }
    if (listen(fd, 8) < 0) {
        perror("listen(tcp)");
        close(fd);
        return -1;
    }
    return fd;
}

int main(int argc, char* argv[]) {
    Args args = parse_args(argc, argv);

    // Capabilities listing for Kismet GUI discovery
    if (args.list_only) {
        std::cout
            << "{"
            << "\"sourcetype\":\"cell\","
            << "\"description\":\"Cellular capture (Android feeder)\","
            << "\"preferred_name\":\"cell\","
            << "\"default_source\":\"uds:" << args.socket_path << "\","
            << "\"supports_local\":true,"
            << "\"supports_remote\":true,"
            << "\"options\":["
                << "{"
                    << "\"name\":\"socket\","
                    << "\"type\":\"string\","
                    << "\"default\":\"" << args.socket_path << "\","
                    << "\"description\":\"UNIX domain socket path\""
                << "},"
                << "{"
                    << "\"name\":\"enable_tcp\","
                    << "\"type\":\"bool\","
                    << "\"default\":false,"
                    << "\"description\":\"Enable TCP listener (not enabled by default)\""
                << "},"
                << "{"
                    << "\"name\":\"tcp_port\","
                    << "\"type\":\"int\","
                    << "\"default\":" << args.tcp_port << ","
                    << "\"description\":\"TCP port when enable_tcp is true\""
                << "}"
            << "]"
            << "}\n";
        return 0;
    }

    std::signal(SIGINT, [](int) { g_stop = 1; });
    std::signal(SIGTERM, [](int) { g_stop = 1; });

    int uds_fd = create_uds_listener(args.socket_path);
    if (uds_fd < 0) return 1;
    int tcp_fd = -1;
    if (args.enable_tcp) {
        tcp_fd = create_tcp_listener(args.tcp_port);
        if (tcp_fd < 0) {
            close(uds_fd);
            return 1;
        }
    }

    std::cout << "Listening on UDS: " << args.socket_path << std::endl;
    if (args.enable_tcp) {
        std::cout << "TCP listener enabled on port " << args.tcp_port << std::endl;
    }

    while (!g_stop) {
        fd_set rfds;
        FD_ZERO(&rfds);
        int maxfd = uds_fd;
        FD_SET(uds_fd, &rfds);
        if (tcp_fd >= 0) {
            FD_SET(tcp_fd, &rfds);
            if (tcp_fd > maxfd) maxfd = tcp_fd;
        }
        timeval tv{1, 0};
        int rv = select(maxfd + 1, &rfds, nullptr, nullptr, &tv);
        if (rv < 0) {
            if (errno == EINTR) continue;
            perror("select");
            break;
        }
        if (rv == 0) continue;
        if (FD_ISSET(uds_fd, &rfds)) {
            int c = accept(uds_fd, nullptr, nullptr);
            if (c >= 0) {
                std::thread(handle_client, c, "uds").detach();
                std::cout << "[uds] client connected" << std::endl;
            }
        }
        if (tcp_fd >= 0 && FD_ISSET(tcp_fd, &rfds)) {
            sockaddr_in addr{};
            socklen_t len = sizeof(addr);
            int c = accept(tcp_fd, reinterpret_cast<sockaddr*>(&addr), &len);
            if (c >= 0) {
                char ip[64];
                inet_ntop(AF_INET, &addr.sin_addr, ip, sizeof(ip));
                std::stringstream tag;
                tag << "tcp:" << ip << ":" << ntohs(addr.sin_port);
                std::thread(handle_client, c, tag.str()).detach();
                std::cout << "[" << tag.str() << "] client connected" << std::endl;
            }
        }
    }

    if (uds_fd >= 0) close(uds_fd);
    if (tcp_fd >= 0) close(tcp_fd);
    unlink(args.socket_path.c_str());
    std::cout << "Shutting down" << std::endl;
    return 0;
}
