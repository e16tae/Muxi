# Contributing to Muxi

Thank you for your interest in contributing to Muxi! This guide will help you get started.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/Muxi.git`
3. Set up your development environment: see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
4. Create a branch: `git checkout -b feat/your-feature`

## Development Workflow

### Branch Naming

| Prefix | Use |
|--------|-----|
| `feat/` | New features |
| `fix/` | Bug fixes |
| `docs/` | Documentation changes |
| `refactor/` | Code refactoring |
| `test/` | Test additions or fixes |
| `ci/` | CI/CD changes |

### Commit Messages

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(terminal): add true color support
fix(ssh): handle connection timeout gracefully
docs(readme): update build instructions
test(parser): add edge cases for VT escape sequences
```

Format: `type(scope): description`

- **type**: feat, fix, docs, refactor, test, ci, chore
- **scope**: terminal, ssh, tmux, parser, ui, core (optional)
- **description**: lowercase, imperative mood, no period

### Pull Request Process

1. Ensure your code builds without warnings
2. Run all tests and confirm they pass:
   ```bash
   xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi \
     -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' \
     CODE_SIGNING_ALLOWED=NO
   swift test --package-path ios/MuxiCore
   ```
3. Update documentation if your change affects public APIs or behavior
4. Open a pull request against `main`
5. Fill out the PR template
6. Wait for CI checks to pass and a review from a maintainer

### PR Requirements

- All CI checks must pass
- At least one maintainer approval
- Squash merge into `main`
- Branch deleted after merge

## Code Style

- **Swift**: See [docs/guides/swift-style.md](docs/guides/swift-style.md)
- **C**: See [docs/guides/c-style.md](docs/guides/c-style.md)
- **Testing**: See [docs/guides/testing.md](docs/guides/testing.md)

### Key Rules

- Use `@MainActor @Observable` for ViewModels (not `ObservableObject`)
- Use `shellEscaped()` for all user input in SSH commands
- Use `withCString` scope for C parser pointer safety
- Prefix C functions: `vt_` for VT parser, `tmux_` for tmux protocol

## Reporting Issues

- Use the [bug report template](https://github.com/e16tae/Muxi/issues/new?template=bug_report.yml) for bugs
- Use the [feature request template](https://github.com/e16tae/Muxi/issues/new?template=feature_request.yml) for ideas
- Check existing issues before creating a new one

## Security

If you find a security vulnerability, please report it privately. See [SECURITY.md](SECURITY.md) for details.

## License

By contributing to Muxi, you agree that your contributions will be licensed under the [MIT License](LICENSE).
