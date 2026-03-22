# ADR-0009: Embedded Tailscale Userspace Networking

## Status

Accepted

## Context

Users on Tailscale/Headscale networks need to SSH to machines that are only reachable via their tailnet. iOS allows only one system VPN at a time, so a Network Extension approach would conflict with any existing VPN.

## Decision

Embed a Tailscale node using **libtailscale** (C API over tsnet via gomobile) with **userspace networking**. This runs entirely within Muxi's process, does not consume the system VPN slot, and coexists with any active VPN.

Key choices:
- **libtailscale** over raw WireGuard+Headscale API — uses the official Tailscale client stack, minimizing reimplementation
- **Userspace (tsnet)** over Network Extension — avoids VPN slot conflict and Apple entitlement requirements
- **gomobile xcframework** — consistent with existing libssh2/OpenSSL build pipeline
- **fd passthrough** — libtailscale's `dial()` returns a file descriptor that plugs directly into `libssh2_session_handshake(session, fd)`, requiring minimal changes to the SSH stack

## Consequences

- Binary size increases ~15-25MB due to embedded Go runtime
- Go toolchain (+ gomobile) added as build dependency
- TailscaleService actor manages fd lifecycle — SSHService must not close Tailscale-provided fds
- Pre-auth key authentication only (Headscale); OAuth not supported initially
- Background behavior: tsnet goroutines freeze when iOS suspends the app; reconnection happens automatically on foreground resume
