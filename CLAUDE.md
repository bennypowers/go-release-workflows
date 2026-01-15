# go-release-workflows

Shared GitHub Actions workflows for cross-compiling Go binaries with CGO enabled.

## Architecture

- **Reusable workflows**: `build-binaries.yml` and `npm-publish.yml` use `workflow_call` trigger
- **Composite actions**: All shell logic extracted to `.sh` scripts in `.github/actions/*/`
- **Script references**: Use `${{ github.action_path }}/script.sh` pattern
- **Containerfile**: Embedded in `setup-windows-build` action (not repo root)

## Validation

Before committing, run:
```bash
actionlint .github/workflows/*.yml
shellcheck .github/actions/*/*.sh
```

## Key Conventions

- Platform names: `linux-x64`, `linux-arm64`, `darwin-x64`, `darwin-arm64`, `win32-x64`, `win32-arm64`
- Output path: `dist/bin/<binary-name>-<platform>[.exe]`
- Windows cross-compilation uses llvm-mingw in Fedora container via podman
- Node.js version detection: `.nvmrc` > `.node-version` > `package.json engines.node` > `lts/*`
- ldflags: Always use `-s -w` for consistent binary sizes across all build paths
- Windows containers need Go env vars passed explicitly: `GOEXPERIMENT`, `GOTAGS`, etc.

## Common Issues (Learnings)

1. **GOOS=windows required**: The shared Containerfile sets `GOOS=windows` explicitly. Without this, Go compiles Linux CGO runtime, causing `sigset_t` errors.

2. **GOEXPERIMENT passthrough**: If a project uses `GOEXPERIMENT` (e.g., cem uses `jsonv2`), it must be passed to Windows containers via `-e GOEXPERIMENT=$(GOEXPERIMENT)` in podman run.

3. **ldflags consistency**: Size mismatches during migration are usually from inconsistent ldflags. The shared workflow uses `-s -w`. Projects must update:
   - Makefile's `GO_BUILD_FLAGS`
   - `.goreleaser.yaml` ldflags (if using GoReleaser)
   - Any custom Containerfiles

4. **validate-build strict mode**: Hash mismatches are expected when comparing builds from different toolchains (GoReleaser vs Makefile). Use `strict: false` to warn instead of fail.

5. **BuildID differences**: The `file` command output includes BuildID which differs between builds. validate-build uses regex patterns for architecture checks, not exact string matching.

## Why Not GoReleaser?

We evaluated goreleaser-cross but chose Make-based approach because:
1. **win32-arm64 broken**: [Issue #117](https://github.com/goreleaser/goreleaser-cross/issues/117) - ARM64 compiler missing
2. **Full control**: Projects own build logic in Makefile
3. **Debuggable**: `make linux-x64` works locally exactly as in CI
4. **darwin needs native runners anyway**: Even goreleaser-cross recommends macOS runners for CGO

## Consuming Projects

- cem, dtls, mappa, design-tokens extractor
- VSCode/Zed publishing stays in project workflows (out of scope here)
