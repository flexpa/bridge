#include "clibproc.h"

#include <arpa/inet.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <unistd.h>

int clp_pid_uid(pid_t pid) {
    struct proc_bsdshortinfo info;
    int n = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, sizeof(info));
    if (n != (int)sizeof(info)) return -1;
    return (int)info.pbsi_uid;
}

pid_t clp_parent_pid(pid_t pid) {
    struct proc_bsdshortinfo info;
    int n = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, sizeof(info));
    if (n != (int)sizeof(info)) return -1;
    return (pid_t)info.pbsi_ppid;
}

int clp_pid_path(pid_t pid, char *buf, uint32_t bufsize) {
    int n = proc_pidpath(pid, buf, bufsize);
    return n > 0 ? n : 0;
}

static int pid_owns_tcp_socket(pid_t pid, uint16_t peer_port, uint16_t server_port) {
    int bufsize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bufsize <= 0) return 0;

    struct proc_fdinfo *fds = malloc((size_t)bufsize);
    if (!fds) return 0;

    int got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bufsize);
    if (got <= 0) {
        free(fds);
        return 0;
    }

    int count = got / PROC_PIDLISTFD_SIZE;
    int found = 0;
    for (int i = 0; i < count && !found; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;

        struct socket_fdinfo si;
        memset(&si, 0, sizeof(si));
        int n = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, sizeof(si));
        if (n != (int)sizeof(si)) continue;
        if (si.psi.soi_kind != SOCKINFO_TCP) continue;

        struct in_sockinfo *ini = &si.psi.soi_proto.pri_tcp.tcpsi_ini;
        uint16_t lport = ntohs((uint16_t)ini->insi_lport);
        uint16_t fport = ntohs((uint16_t)ini->insi_fport);
        if (lport == peer_port && fport == server_port) {
            found = 1;
        }
    }
    free(fds);
    return found;
}

int clp_find_pid_for_tcp_peer(uint16_t peer_port, uint16_t server_port, pid_t *out_pid) {
    if (!out_pid) return -1;

    int capacity = proc_listallpids(NULL, 0);
    if (capacity <= 0) return -1;
    capacity += 128;

    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    if (!pids) return -1;

    int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    if (count <= 0) {
        free(pids);
        return -1;
    }

    uid_t me = getuid();
    int result = 1;
    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        // Only same-user processes can be inspected without privileges.
        if (clp_pid_uid(pid) != (int)me) continue;
        if (pid_owns_tcp_socket(pid, peer_port, server_port)) {
            *out_pid = pid;
            result = 0;
            break;
        }
    }
    free(pids);
    return result;
}
