# Release Process

## Versioning

Muxi follows [Semantic Versioning](https://semver.org/) (SemVer):

```
MAJOR.MINOR.PATCH
```

| Component | When to bump |
|-----------|-------------|
| **MAJOR** | Breaking changes to saved data, SSH behavior, or public APIs |
| **MINOR** | New features, backward-compatible enhancements |
| **PATCH** | Bug fixes, performance improvements, documentation updates |

## Pre-release Versions

During early development (v0.x), minor version bumps may include breaking changes.

Format: `0.MINOR.PATCH` (e.g., `0.1.0`, `0.2.0`)

## Release Checklist

### 1. Prepare

- [ ] All CI checks pass on `main`
- [ ] All tests pass locally:
  ```bash
  ./scripts/build-all.sh
  cd ios && xcodegen generate
  xcodebuild test -project Muxi.xcodeproj -scheme Muxi \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
  swift test --package-path MuxiCore
  ```
- [ ] `CHANGELOG.md` updated with new version section
- [ ] Version bumped in `project.yml`

### 2. Tag

```bash
git tag -a v0.X.0 -m "Release v0.X.0"
git push origin v0.X.0
```

### 3. Release

- [ ] Create GitHub Release from the tag
- [ ] Copy relevant `CHANGELOG.md` section into release notes
- [ ] Attach any relevant build artifacts

### 4. Post-release

- [ ] Bump version in `project.yml` to next development version
- [ ] Add new `## [Unreleased]` section to `CHANGELOG.md`

## Changelog Format

Follow [Keep a Changelog](https://keepachangelog.com/) format:

```markdown
## [0.2.0] - 2026-XX-XX

### Added
- Real SSH connections via libssh2

### Changed
- Updated terminal rendering pipeline

### Fixed
- Connection timeout handling
```

Categories: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`

## Hotfix Process

For critical fixes on a released version:

1. Branch from the release tag: `git checkout -b hotfix/description v0.X.0`
2. Apply fix, update CHANGELOG, bump PATCH version
3. Merge to `main` and tag new release
