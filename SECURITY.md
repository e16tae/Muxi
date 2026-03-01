# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | Yes       |

## Reporting a Vulnerability

If you discover a security vulnerability in Muxi, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, please email the maintainers directly or use GitHub's private vulnerability reporting feature:

1. Go to the [Security Advisories](https://github.com/e16tae/Muxi/security/advisories) page
2. Click "Report a vulnerability"
3. Provide a detailed description of the issue

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial assessment**: Within 1 week
- **Fix release**: Dependent on severity, typically within 2 weeks for critical issues

## Security Considerations

Muxi handles SSH connections and credentials. Key security areas:

### Credential Storage
- All passwords and private keys are stored in the iOS Keychain
- Never stored in SwiftData, UserDefaults, or plain files
- Never logged, even at debug level

### SSH Command Safety
- All user input passed to SSH commands must use `shellEscaped()`
- Raw string interpolation into shell commands is prohibited
- See [CONTRIBUTING.md](CONTRIBUTING.md) for code style requirements

### Network Security
- SSH connections use libssh2 with standard key exchange algorithms
- No custom cryptography implementations
