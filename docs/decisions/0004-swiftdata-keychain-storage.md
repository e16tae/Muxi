# ADR-0004: SwiftData for persistence, Keychain for secrets

## Status

Accepted

## Date

2026-02-28

## Context

Muxi stores two categories of data: server metadata (host, port, username, auth method) and secrets (passwords, SSH private keys). These have different security requirements and access patterns.

## Decision

- **Server metadata**: SwiftData with `@Model` macros. Queryable, supports migration, modern Swift integration.
- **Passwords and SSH keys**: iOS Keychain via `KeychainService`. Encrypted at rest by the OS.
- **User preferences** (theme, font size): UserDefaults. Simple key-value pairs.
- **Last-used session per server**: UserDefaults via `LastSessionStore`.

Secrets are **never** stored in SwiftData, UserDefaults, or logged at any level.

## Alternatives Considered

### Core Data for everything

Use Core Data for both metadata and secrets (encrypted attributes).

Rejected because:
- Core Data encrypted attributes are application-level encryption — less secure than Keychain (hardware-backed on devices with Secure Enclave)
- Core Data API is verbose compared to SwiftData's `@Model` macros
- SwiftData is the modern replacement, better Swift integration

### Keychain for everything

Store server metadata in Keychain alongside secrets.

Rejected because:
- Keychain is not designed for queryable structured data (no sorting, filtering, relationships)
- Keychain API is awkward for non-secret data
- Migration between versions is harder with Keychain than SwiftData

## Consequences

- (+) Secrets benefit from hardware-backed encryption (Secure Enclave)
- (+) SwiftData provides modern, ergonomic persistence for structured data
- (+) Clear separation: metadata in SwiftData, secrets in Keychain — auditable boundary
- (-) Two storage systems to manage
- (-) Server deletion must clean up both SwiftData record and Keychain entries
- (-) Simulator builds require signing entitlements for Keychain access (`CODE_SIGNING_ALLOWED=NO` breaks Keychain)
