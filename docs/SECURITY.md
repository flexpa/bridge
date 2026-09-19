# Security

Health Bridge holds the HealthKit grant (or an imported copy of your Health data) and hands data to agents. It
must not become the easiest way for anything on the machine to read that data.

## Threat model

Assets: the person's health data, including FHIR clinical records.

Adversaries considered:

1. **Other software on the same Mac, same user account** (a malicious npm package, a curious Electron app,
   a browser page). This is the main threat: loopback is reachable by all of them.
2. **Other user accounts on the same Mac.** They can connect to `127.0.0.1` too.
3. **Web pages** performing DNS rebinding or CSRF against `localhost`.
4. **An agent that was paired and later turns hostile or leaks its config file.**
5. **Someone with the pairings file** (backup, sync, theft).

Out of scope: root or an attacker who can inject code into an approved, hardened, signed process; Apple's own
HealthKit permission model; what an agent does with data after it legitimately receives it.

## Controls

| Layer | Control | Defeats |
| --- | --- | --- |
| Network | `NWListener` bound to `127.0.0.1` with `requiredLocalEndpoint`, `acceptLocalOnly`. Never `0.0.0.0`. | Remote hosts |
| HTTP | `Host` must be loopback; `Origin`, if present, must be loopback or `null`; cross-site `Sec-Fetch-*` refused. | DNS rebinding, browser CSRF |
| Auth | Bearer token per agent, 256-bit random, `hkb_` prefix. Only SHA-256 hashes at rest; constant-time compare; full scan so timing does not reveal position. | Unauthenticated local callers, stolen `pairings.json` |
| Binding | On first authenticated request the bridge maps the peer's ephemeral port to a pid (`libproc`) and reads its code signature (`SecCodeCopyGuestWithAttributes`, `SecCodeCopySigningInformation`, `anchor apple` check). The pairing is locked to `team:<TeamID>` or `apple:<identifier>`. Later requests must match. Unverifiable peers are then refused. **Strength depends on what the agent is — read the next section before relying on it.** | Token replayed by other software, where the agent has its own signing identity |
| Sessions | `Mcp-Session-Id` issued on `initialize`, tied to the pairing; a session from another pairing is refused. | Session confusion |
| Scope | Read-only tools, no writes to HealthKit. Clinical records can be switched off globally. | Blast radius |
| Audit | Every request (allowed, denied, errored) appended to `audit.jsonl` with pairing, peer, tool, arguments summary, duration. Visible in the panel. | Silent misuse |
| Storage | State directory `0700`, files `0600`. No plaintext tokens anywhere the app controls. | Casual disclosure |
| Hardening | Ad-hoc dev builds carry no restricted entitlements. Release builds: hardened runtime, timestamped Developer ID signature, notarized. | Tampered downloads, library injection |
| Abuse | 64 concurrent connections, 8 MB bodies, 5 auth failures per connection then close. | Local DoS nuisance |

## What binding actually buys, per agent

Measured, not assumed. The protection is only as specific as the caller's signing identity:

| Agent shape | Binds to | What a stolen token gets an attacker |
| --- | --- | --- |
| An app with its own Developer ID team (Claude Desktop, Cursor, OpenCode) | that team | Nothing. Replay from any other program is refused. |
| A program run by a shared interpreter (Claude Code under Node) | the interpreter's team | Any program that interpreter can run. For Node that is any script. |
| An ad-hoc or unsigned binary (Homebrew's `node`, local builds) | **nothing** | Full use of the token, forever. There is no identity to pin. |

So for an Electron app the control is strong. For a Node-based agent it narrows the attacker to
"anything runnable by Node", which on a developer's machine is close to everything. For an ad-hoc
binary it provides nothing at all, and the pairing shows an **open lock** in the panel to say so.

A pairing is also unprotected before its first use, since there is nothing to compare against yet.
Treat a freshly created token as a plain secret until the panel shows it locked.

If this matters to you, pair the agents that ship as signed applications, and check the lock icon.

## Why bind tokens to a code-signing identity

A bearer token in `~/.claude.json` or `~/.cursor/mcp.json` is readable by every process the user runs. Peer
identity turns "who has the string" into "which signed program is asking". Apple's own TCC works the same way.
It is best-effort by design:

* Identification uses the client's local TCP port, found by scanning same-user sockets with `proc_pidfdinfo`.
  This is the mechanism `lsof` uses; there is no public API for it. A failed lookup is treated as "unknown".
* Binding happens on first use (trust on first use). The panel shows exactly what a token is bound to and offers
  **Reset App Binding** when the user moves a token to a different app on purpose.
* Ad-hoc signed binaries (Homebrew Python and Node, local builds) have no stable identity, so they are allowed but
  never bound, and the check is skipped for them on every later request too. The panel shows an open lock.
* Apple platform binaries (`curl`, `/usr/bin/python3` via Xcode) bind by identifier. Testing with `curl` binds the
  token to curl; reset before handing it to the real agent.

## Options we considered for "how does the agent authenticate"

**Bearer token, created in the app, pasted into the client (chosen).** Works with every MCP client that speaks
Streamable HTTP with headers (Claude Code, Cursor, VS Code, Claude Desktop through `mcp-remote`). Zero protocol
surface beyond one header. Weakness: a secret at rest in the client config, mitigated by binding above.

**OAuth 2.1 authorization server on loopback.** MCP's official auth story. The client discovers
`/.well-known/oauth-authorization-server`, registers dynamically, opens a browser to `/authorize`, the app shows
an approve sheet, tokens are issued with PKCE and refresh. Pros: no copy and paste, native "Allow Claude to read
your health data?" prompt, revocation by refresh failure. Cons for v1: a full AS (DCR, PKCE, token endpoint,
refresh, revocation, metadata) is a few hundred lines of security-sensitive code; the browser hop is odd for a
menu bar utility; the resulting access token is still a bearer secret in the client's store, so it does not
replace binding. It is a good v2 once the token model is proven. The pairing store is already shaped for it
(one record per client, hash at rest, bound identity).

**Unix domain socket + stdio shim.** Filesystem permissions give same-user-only for free and `LOCAL_PEERPID`
gives the pid without scanning. Downside: MCP clients do not speak Unix sockets, so we would ship a stdio proxy
binary and the "peer" becomes the proxy, forcing a walk up the process tree to find the real agent. Streamable
HTTP on loopback plus port-to-pid lookup gets the same identity with no shim.

**mTLS on loopback.** Strong, but no MCP client supports client certificates out of the box.

## Known limitations

* Binding is only as narrow as the caller's signing identity, and is absent for ad-hoc binaries. See the table above.
* Peer identification cannot see processes owned by other users; those are refused only after a pairing is
  bound. Until first use, a token is usable by anyone who has it.
* Identity is resolved from the peer's pid. Apple's stronger primitive is the connection's audit token, which
  loopback TCP does not expose; a Unix-socket transport would allow it and is the intended hardening.
* Process identity is checked per connection, not per request; HTTP keep-alive reuses the verdict for the life
  of the socket.
* The app is not sandboxed (Developer ID does not require it). Sandboxing would break `proc_pidinfo` on other
  processes and `SecCodeCopyGuestWithAttributes` by pid.
* An agent that legitimately reads data can do anything with it. The audit log records what was asked, not what
  happened afterwards.

## Reporting

Security issues: security@flexpa.com.
