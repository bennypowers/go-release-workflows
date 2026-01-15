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

## Why Not GoReleaser?

We evaluated goreleaser-cross but chose Make-based approach because:
1. **win32-arm64 broken**: [Issue #117](https://github.com/goreleaser/goreleaser-cross/issues/117) - ARM64 compiler missing
2. **Full control**: Projects own build logic in Makefile
3. **Debuggable**: `make linux-x64` works locally exactly as in CI
4. **darwin needs native runners anyway**: Even goreleaser-cross recommends macOS runners for CGO

## Consuming Projects

- cem, dtls, mappa, design-tokens extractor
- VSCode/Zed publishing stays in project workflows (out of scope here)
