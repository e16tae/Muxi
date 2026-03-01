# Git Workflow

## Branch Strategy

Single `main` branch with feature branches:

```
main ← feat/terminal-colors
     ← fix/ssh-timeout
     ← docs/architecture-update
```

### Branch Naming

```
type/short-description
```

| Prefix | Use |
|--------|-----|
| `feat/` | New features |
| `fix/` | Bug fixes |
| `docs/` | Documentation |
| `refactor/` | Code restructuring |
| `test/` | Test additions |
| `ci/` | CI/CD changes |

## Commit Messages

[Conventional Commits](https://www.conventionalcommits.org/) format:

```
type(scope): description

Optional body explaining why, not what.
```

### Types

| Type | When |
|------|------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `refactor` | No behavior change |
| `test` | Test additions/fixes |
| `ci` | CI/CD changes |
| `chore` | Maintenance, deps |

### Scopes

`terminal`, `ssh`, `tmux`, `parser`, `ui`, `core`, `renderer`

### Examples

```
feat(terminal): add true color (24-bit) support
fix(ssh): handle connection timeout with exponential backoff
docs(readme): update build instructions for Xcode 15
test(parser): add edge cases for CSI parameter overflow
refactor(renderer): extract glyph cache into separate struct
ci: add Core C test workflow for pull requests
```

## Pull Request Process

1. Create feature branch from `main`
2. Make focused, atomic commits
3. Push branch and open PR
4. Fill out PR template
5. Wait for CI + maintainer review
6. Squash merge into `main`
7. Delete branch after merge

## Merge Strategy

- **Squash merge** for feature branches (clean history)
- **Merge commit** only for release branches or large collaborative work
- **Never** force push to `main`

## Release Tags

```bash
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

See [docs/RELEASE.md](../RELEASE.md) for the full release process.
