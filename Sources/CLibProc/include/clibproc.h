#ifndef CLIBPROC_H
#define CLIBPROC_H

#include <sys/types.h>
#include <stdint.h>

/// Finds the process that owns the client side of an established loopback TCP
/// connection. `peer_port` is the client's local port as seen by the server
/// (the remote port of the accepted socket). `server_port` is the port the
/// server listens on. Both are in host byte order.
///
/// Only processes owned by the calling user are inspectable without root, so
/// this returns 1 (not found) for connections made by other local users.
///
/// Returns 0 and sets *out_pid on success, 1 if no owner was found, -1 on error.
int clp_find_pid_for_tcp_peer(uint16_t peer_port, uint16_t server_port, pid_t *out_pid);

/// Copies the executable path of `pid` into `buf`. Returns the length, or 0 on failure.
int clp_pid_path(pid_t pid, char *buf, uint32_t bufsize);

/// Returns the parent pid of `pid`, or -1 on failure.
pid_t clp_parent_pid(pid_t pid);

/// Returns the uid that owns `pid`, or -1 on failure.
int clp_pid_uid(pid_t pid);

/// Parses a HealthKit unit string, returning a retained HKUnit (as an opaque
/// pointer) or NULL when the string is not a valid unit. HKUnit throws an
/// Objective-C exception on bad input, which Swift cannot catch; this wraps it.
void *hb_unit_from_string(const char *utf8);

#endif
