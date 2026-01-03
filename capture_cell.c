/*
 * kismet_cap_cell_capture - External capture for cellular JSON feed
 * Wraps the phone/collector JSON stream (TCP) into the Kismet external capture
 * protocol using the vendored capture framework (vendor/).
 */

#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

#include "vendor/config.h"
#include "vendor/capture_framework.h"
#include "vendor/simple_ringbuf_c.h"
#include "vendor/kis_external_packet.h"

#define DEFAULT_HOST "127.0.0.1"
#define DEFAULT_PORT 8765

/*
 * Userdata for this capture instance
 */
typedef struct {
    char *host;
    int port;
    int sockfd;
    pthread_t reader_thread;
    int running;
} cell_cap_t;

static void usage(const char *prog) {
    fprintf(stderr, "Usage: %s [--host HOST] [--port PORT]\n", prog);
}

static int connect_socket(const char *host, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) <= 0) {
        close(fd);
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void *reader_thread(void *aux) {
    kis_capture_handler_t *caph = (kis_capture_handler_t *) aux;
    cell_cap_t *cap = (cell_cap_t *) caph->userdata;
    char buf[8192];
    size_t nbuf = 0;
    while (cap->running) {
        if (cap->sockfd < 0) {
            cap->sockfd = connect_socket(cap->host, cap->port);
            if (cap->sockfd < 0) {
                sleep(1);
                continue;
            }
            nbuf = 0;
        }

        ssize_t n = read(cap->sockfd, buf + nbuf, sizeof(buf) - nbuf);
        if (n <= 0) {
            close(cap->sockfd);
            cap->sockfd = -1;
            sleep(1);
            continue;
        }
        nbuf += n;
        size_t start = 0;
        for (size_t i = 0; i < nbuf; i++) {
            if (buf[i] == '\n') {
                size_t len = i - start;
                if (len > 0) {
                    struct timeval tv;
                    gettimeofday(&tv, NULL);
                    char *line = (char *) malloc(len + 1);
                    memcpy(line, buf + start, len);
                    line[len] = '\0';
                    cf_send_json(caph,
                                 NULL, /* message */
                                 0,    /* msg_type */
                                 NULL, /* signal */
                                 NULL, /* gps */
                                 tv,
                                 "cell",
                                 line);
                    free(line);
                }
                start = i + 1;
            }
        }
        if (start > 0) {
            memmove(buf, buf + start, nbuf - start);
            nbuf -= start;
        }
        if (nbuf == sizeof(buf)) {
            nbuf = 0; /* drop overlong line */
        }
    }
    cap->running = 0;
    return NULL;
}

/* Minimal capture callback to keep the capture thread alive */
static void capture_cb(kis_capture_handler_t *caph) {
    cell_cap_t *cap = (cell_cap_t *) caph->userdata;
    while (cap && cap->running) {
        sleep(1);
    }
}

static int list_cb(kis_capture_handler_t *caph, uint32_t seqno, char *msg,
                   cf_params_list_interface_t ***interfaces) {
    *interfaces = (cf_params_list_interface_t **) malloc(sizeof(cf_params_list_interface_t *));
    (*interfaces)[0] = (cf_params_list_interface_t *) malloc(sizeof(cf_params_list_interface_t));
    memset((*interfaces)[0], 0, sizeof(cf_params_list_interface_t));
    (*interfaces)[0]->interface = strdup("cellstream");
    (*interfaces)[0]->flags = strdup("");
    (*interfaces)[0]->hardware = strdup("");
    return 1;
}

static int probe_cb(kis_capture_handler_t *caph, uint32_t seqno, char *definition,
                    char *msg, char **uuid, cf_params_interface_t **ret_interface,
                    cf_params_spectrum_t **ret_spectrum) {
    *uuid = strdup("cellstream-uuid");
    *ret_interface = cf_params_interface_new();
    (*ret_interface)->capif = strdup("cellstream");
    (*ret_interface)->chanset = NULL;
    (*ret_interface)->channels = NULL;
    (*ret_interface)->channels_len = 0;
    (*ret_interface)->hardware = strdup("");
    *ret_spectrum = NULL;
    return 1;
}

static int open_cb(kis_capture_handler_t *caph, uint32_t seqno, char *definition,
                   char *msg, uint32_t *dlt, char **uuid,
                   cf_params_interface_t **ret_interface, cf_params_spectrum_t **ret_spectrum) {
    cell_cap_t *cap = (cell_cap_t *) caph->userdata;

    /* Parse optional host:port from definition tcp://host:port */
    if (definition) {
        const char *tcp = strstr(definition, "tcp://");
        if (tcp) {
            const char *h = tcp + strlen("tcp://");
            const char *colon = strchr(h, ':');
            if (colon) {
                free(cap->host);
                cap->host = strndup(h, colon - h);
                cap->port = atoi(colon + 1);
            }
        }
    }
    if (!cap->host) cap->host = strdup(DEFAULT_HOST);
    if (cap->port <= 0) cap->port = DEFAULT_PORT;

    cap->sockfd = -1;
    cap->running = 1;
    if (pthread_create(&cap->reader_thread, NULL, reader_thread, caph) != 0) {
        snprintf(msg, STATUS_MAX, "Failed to start reader thread");
        cap->running = 0;
        return -1;
    }

    *uuid = strdup("cellstream-uuid");
    *ret_interface = cf_params_interface_new();
    (*ret_interface)->capif = strdup("cellstream");
    (*ret_interface)->chanset = NULL;
    (*ret_interface)->channels = NULL;
    (*ret_interface)->channels_len = 0;
    (*ret_interface)->hardware = strdup("");
    *ret_spectrum = NULL;
    *dlt = 0; /* unknown/raw */
    return 0;
}

static void shutdown_capture(kis_capture_handler_t *caph) {
    cell_cap_t *cap = (cell_cap_t *) caph->userdata;
    if (!cap) return;
    cap->running = 0;
    if (cap->sockfd > 0) close(cap->sockfd);
    if (cap->reader_thread) pthread_join(cap->reader_thread, NULL);
}

int main(int argc, char *argv[]) {
    const char *host = DEFAULT_HOST;
    int port = DEFAULT_PORT;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--host") && i + 1 < argc) {
            host = argv[++i];
        } else if (!strcmp(argv[i], "--port") && i + 1 < argc) {
            port = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(argv[0]);
            return 0;
        }
    }

    cell_cap_t cap = {0};
    cap.host = strdup(host);
    cap.port = port;

    kis_capture_handler_t *caph = cf_handler_init("cell");
    if (caph == NULL) {
        fprintf(stderr, "Failed to init capture handler\n");
        return -1;
    }

    cf_handler_set_userdata(caph, &cap);
    cf_handler_set_listdevices_cb(caph, list_cb);
    cf_handler_set_probe_cb(caph, probe_cb);
    cf_handler_set_open_cb(caph, open_cb);
    cf_handler_set_capture_cb(caph, capture_cb);

    if (cf_handler_parse_opts(caph, argc, argv) < 1) {
        cf_print_help(caph, argv[0]);
        return -1;
    }

    cf_handler_remote_capture(caph);
    cf_handler_loop(caph);
    shutdown_capture(caph);
    cf_handler_free(caph);
    return 0;
}
