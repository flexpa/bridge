# Security policy

Flexpa Health Bridge holds a copy of a person's health data and serves it to local agents, so we take reports
seriously and answer quickly.

## Reporting

Report privately through [GitHub's advisory form](https://github.com/flexpa/bridge/security/advisories/new), or
email security@flexpa.com. Please do not open a public issue for a vulnerability.

Include what you can: the version, the macOS version, what an attacker gains, and a reproduction. We aim to
acknowledge within two business days and to ship a fix or a mitigation plan within thirty days.

## Scope

In scope: anything that lets software on the Mac read health data without a pairing the user created, bypass the
code-signature binding on a pairing token, reach the server from off the machine, escape the loopback or origin
checks, or recover backup passwords or decryption keys from disk or memory beyond their documented lifetime.

Out of scope: an attacker who already has root or can inject code into an approved, signed agent; what a paired
agent does with data it was legitimately given; and Apple's own HealthKit and TCC permission models.

The threat model and controls are documented in [docs/SECURITY.md](docs/SECURITY.md).
