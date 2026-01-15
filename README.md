# go-release-workflows

Shared GitHub Actions workflows for cross-compiling Go binaries with CGO enabled.

## Features

- **6 platforms**: linux-x64, linux-arm64, darwin-x64, darwin-arm64, win32-x64, win32-arm64
- **CGO enabled**: Supports tree-sitter, SQLite, and other C dependencies
- **GitHub Release uploads**: Automatically upload binaries to releases
- **PR validation**: Build artifacts with status comments on pull requests
- **Optional npm publishing**: Platform-specific packages + main wrapper package

## Makefile Contract

Your project must provide a Makefile with targets for each platform. The workflow delegates all build logic to your Makefile.

### Required Targets

```makefile
linux-x64:      # Build for Linux x86_64
linux-arm64:    # Build for Linux ARM64
darwin-x64:     # Build for macOS x86_64
darwin-arm64:   # Build for macOS ARM64
win32-x64:      # Build for Windows x64
win32-arm64:    # Build for Windows ARM64
```

### Output Convention

All targets must output binaries to:

```
dist/bin/<binary-name>-<platform>[.exe]
```

Examples:
- `make linux-x64` → `dist/bin/myapp-linux-x64`
- `make win32-arm64` → `dist/bin/myapp-win32-arm64.exe`

### Example Makefile

```makefile
BINARY_NAME := myapp
DIST_DIR := dist/bin
GO_BUILD_FLAGS := -ldflags="-s -w"
WINDOWS_CC_IMAGE := $(BINARY_NAME)-windows-cc

.PHONY: linux-x64 linux-arm64 darwin-x64 darwin-arm64 win32-x64 win32-arm64

linux-x64:
	@mkdir -p $(DIST_DIR)
	CGO_ENABLED=1 GOOS=linux GOARCH=amd64 \
		go build $(GO_BUILD_FLAGS) -o $(DIST_DIR)/$(BINARY_NAME)-linux-x64 .

linux-arm64:
	@mkdir -p $(DIST_DIR)
	CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC=aarch64-linux-gnu-gcc \
		go build $(GO_BUILD_FLAGS) -o $(DIST_DIR)/$(BINARY_NAME)-linux-arm64 .

darwin-x64:
	@mkdir -p $(DIST_DIR)
	CGO_ENABLED=1 GOOS=darwin GOARCH=amd64 \
		go build $(GO_BUILD_FLAGS) -o $(DIST_DIR)/$(BINARY_NAME)-darwin-x64 .

darwin-arm64:
	@mkdir -p $(DIST_DIR)
	CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 \
		go build $(GO_BUILD_FLAGS) -o $(DIST_DIR)/$(BINARY_NAME)-darwin-arm64 .

win32-x64: build-windows-image
	@mkdir -p $(DIST_DIR)
	podman run --rm -v $(PWD):/app:Z -w /app \
		-e GOARCH=amd64 -e BINARY_NAME=$(BINARY_NAME) \
		-e GOEXPERIMENT=$(GOEXPERIMENT) \
		$(WINDOWS_CC_IMAGE)
	@mv $(DIST_DIR)/$(BINARY_NAME)-windows-amd64.exe $(DIST_DIR)/$(BINARY_NAME)-win32-x64.exe

win32-arm64: build-windows-image
	@mkdir -p $(DIST_DIR)
	podman run --rm -v $(PWD):/app:Z -w /app \
		-e GOARCH=arm64 -e BINARY_NAME=$(BINARY_NAME) \
		-e GOEXPERIMENT=$(GOEXPERIMENT) \
		$(WINDOWS_CC_IMAGE)
	@mv $(DIST_DIR)/$(BINARY_NAME)-windows-arm64.exe $(DIST_DIR)/$(BINARY_NAME)-win32-arm64.exe

build-windows-image:
	@if ! podman image exists $(WINDOWS_CC_IMAGE); then \
		podman build -t $(WINDOWS_CC_IMAGE) -f Containerfile.windows . ; \
	fi
```

## Workflows

### build-binaries.yml

Cross-compile Go binaries for all platforms.

#### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `binary-name` | Yes | - | Name of the binary (used for output validation) |
| `platforms` | No | All 6 | JSON array of platforms to build |
| `release-tag` | No | `""` | GitHub release tag to upload to (empty = artifacts only) |

#### Outputs

| Output | Description |
|--------|-------------|
| `artifacts` | JSON array of built artifacts with platform, name, and path |

#### Usage

```yaml
jobs:
  build:
    uses: bennypowers/go-release-workflows/.github/workflows/build-binaries.yml@main
    with:
      binary-name: myapp
      release-tag: ${{ github.event.release.tag_name }}
```

### npm-publish.yml

Publish platform-specific npm packages and a main wrapper package.

#### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `binary-name` | Yes | - | Name of the binary |
| `npm-package-name` | Yes | - | Full npm package name (e.g., `@scope/myapp`) |
| `release-tag` | Yes | - | GitHub release tag |
| `npm-dir` | No | `npm` | Directory containing main package.json |
| `license` | No | Auto-detect | SPDX license identifier (defaults to repo license) |
| `node-version` | No | `lts/*` | Node.js version fallback (see [setup-node](#setup-node)) |

#### Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `npm-token` | Yes | npm publish token |

#### Usage

```yaml
jobs:
  npm:
    needs: build
    uses: bennypowers/go-release-workflows/.github/workflows/npm-publish.yml@main
    with:
      binary-name: myapp
      npm-package-name: "@scope/myapp"
      release-tag: ${{ github.event.release.tag_name }}
    secrets:
      npm-token: ${{ secrets.NPM_TOKEN }}
```

## Example Workflows

### Release with npm

```yaml
name: Release
on:
  release:
    types: [published]

jobs:
  build:
    uses: bennypowers/go-release-workflows/.github/workflows/build-binaries.yml@main
    with:
      binary-name: myapp
      release-tag: ${{ github.event.release.tag_name }}

  npm:
    needs: build
    uses: bennypowers/go-release-workflows/.github/workflows/npm-publish.yml@main
    with:
      binary-name: myapp
      npm-package-name: "@scope/myapp"
      release-tag: ${{ github.event.release.tag_name }}
    secrets:
      npm-token: ${{ secrets.NPM_TOKEN }}
```

### PR Validation

```yaml
name: CI
on:
  pull_request:

jobs:
  build:
    uses: bennypowers/go-release-workflows/.github/workflows/build-binaries.yml@main
    with:
      binary-name: myapp
      # No release-tag = artifacts only + PR comment with build status
```

### Subset of Platforms

```yaml
jobs:
  build:
    uses: bennypowers/go-release-workflows/.github/workflows/build-binaries.yml@main
    with:
      binary-name: myapp
      platforms: '["linux-x64", "darwin-arm64"]'
```

### Manual Dispatch for Existing Releases

To backfill binaries and npm packages for existing releases, add `workflow_dispatch`:

```yaml
name: Release
on:
  release:
    types: [published]
  workflow_dispatch:
    inputs:
      release-tag:
        description: 'Existing release tag to build/publish'
        required: true

jobs:
  build:
    uses: bennypowers/go-release-workflows/.github/workflows/build-binaries.yml@main
    with:
      binary-name: myapp
      release-tag: ${{ github.event.release.tag_name || inputs.release-tag }}

  npm:
    needs: build
    uses: bennypowers/go-release-workflows/.github/workflows/npm-publish.yml@main
    with:
      binary-name: myapp
      npm-package-name: "@scope/myapp"
      release-tag: ${{ github.event.release.tag_name || inputs.release-tag }}
    secrets:
      npm-token: ${{ secrets.NPM_TOKEN }}
```

Then run manually via GitHub UI or CLI:
```bash
gh workflow run release.yml -f release-tag=v0.0.3
```

## Composite Actions

These actions are used internally by the workflows but can also be used directly.

### setup-node

Smart Node.js version detection with fallback.

```yaml
- uses: bennypowers/go-release-workflows/.github/actions/setup-node@main
  with:
    node-version: 'lts/*'  # Fallback if no version file found
    registry-url: 'https://registry.npmjs.org'
```

Detection order:
1. `.nvmrc`
2. `.node-version`
3. `package.json` `engines.node`
4. Fallback to `node-version` input (default: `lts/*`)

### setup-windows-build

Installs podman and provides the shared Containerfile for Windows cross-compilation.

```yaml
- uses: bennypowers/go-release-workflows/.github/actions/setup-windows-build@main
```

### validate-build

Compare two sets of build artifacts for consistency (architecture, size, functionality).

```yaml
- uses: bennypowers/go-release-workflows/.github/actions/validate-build@main
  with:
    expected-dir: artifacts-old    # Reference binaries
    actual-dir: artifacts-new      # New binaries to validate
    size-tolerance: '10'           # Max size difference % (default: 10)
    health-check: 'version'        # Command to verify binary works (optional)
```

Checks performed:
- Architecture verification via `file` command (ELF x86-64, ARM aarch64, Mach-O, PE32+)
- File size within tolerance (default 10%)
- Health check for native binaries (if configured) - runs `<binary> <health-check>`
- File existence

Hash comparison is intentionally omitted - different toolchains, timestamps, and build metadata produce different hashes for functionally equivalent binaries.

### generate-checksums

Generate SHA256 checksums manifest for release artifacts.

```yaml
- uses: bennypowers/go-release-workflows/.github/actions/generate-checksums@main
  with:
    artifacts-dir: dist/bin
    output-file: checksums.txt
    upload-to-release: v1.0.0  # Optional: upload to GitHub release
```

Output format:
```
# SHA256 Checksums
# Generated: 2026-01-15T12:00:00Z

abc123...  myapp-linux-x64
def456...  myapp-darwin-arm64
```

## Migration Validation

Before switching from existing workflows to go-release-workflows, validate that outputs match:

```yaml
name: Validate Migration
on: workflow_dispatch

jobs:
  build-existing:
    # Your existing build workflow
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # ... existing build steps ...
      - uses: actions/upload-artifact@v4
        with:
          name: binaries-existing
          path: dist/bin/

  build-new:
    uses: bennypowers/go-release-workflows/.github/workflows/build-binaries.yml@main
    with:
      binary-name: myapp
      # No release-tag = artifacts only

  validate:
    needs: [build-existing, build-new]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: binaries-existing
          path: expected/

      - uses: actions/download-artifact@v4
        with:
          name: myapp-linux-x64
          path: actual/
      # ... download other platforms ...

      - uses: bennypowers/go-release-workflows/.github/actions/validate-build@main
        with:
          expected-dir: expected
          actual-dir: actual
          size-tolerance: '5'    # Stricter tolerance for migration validation
          health-check: 'version'  # Verify binary runs (use your CLI's command)
```

Run this workflow to verify binaries are architecturally correct, similar in size, and functional, then switch to the new workflow for releases.

## Windows Cross-Compilation

Windows builds use a container with [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) for ARM64 support and mingw64 for x64. The workflow uses the `setup-windows-build` composite action which:

1. Installs podman
2. Copies the shared `Containerfile` to `Containerfile.windows` (if not already present)

Your Makefile's `win32-*` targets should use podman/docker to build and run this container.

## Why Not GoReleaser?

We evaluated [goreleaser-cross](https://github.com/goreleaser/goreleaser-cross) but chose a Make-based approach because:

1. **win32-arm64 is broken**: [Issue #117](https://github.com/goreleaser/goreleaser-cross/issues/117) reports the ARM64 compiler is missing in recent versions
2. **Full control**: Each project owns its build logic in Makefile
3. **Debuggable**: `make linux-x64` works locally exactly as in CI
4. **darwin still needs native runners**: Even goreleaser-cross recommends macOS runners for darwin CGO builds

## Troubleshooting

### Binary size mismatches during migration

If `validate-build` reports size differences between existing and new binaries:

1. **Check ldflags consistency**: Ensure all build paths use the same ldflags. The shared workflow uses `-s -w` (strip debug info). Update your existing builds to match:
   ```makefile
   GO_BUILD_FLAGS := -ldflags="-s -w"
   ```

2. **Check GoReleaser config**: If using GoReleaser for existing builds, its ldflags are in `.goreleaser.yaml`, not your Makefile:
   ```yaml
   builds:
     - ldflags:
         - -s -w
   ```

3. **Check GOEXPERIMENT**: If your project uses `GOEXPERIMENT` (e.g., `jsonv2`), it must be passed to Windows containers. See the example Makefile above.

### Windows CGO compilation errors

If you see errors like `unknown type name 'sigset_t'` or Linux-specific syscall failures when building Windows binaries, the container is missing `GOOS=windows`. The shared `Containerfile.windows` handles this, but if using a custom Containerfile, ensure it sets:

```dockerfile
ENV GOOS=windows
```

### Passing Go environment variables to Windows containers

Windows builds run inside a container, so Go environment variables from your Makefile or shell don't propagate automatically. Pass them explicitly:

```makefile
win32-x64:
	podman run --rm -v $(PWD):/app:Z -w /app \
		-e GOARCH=amd64 \
		-e BINARY_NAME=$(BINARY_NAME) \
		-e GOEXPERIMENT=$(GOEXPERIMENT) \
		-e GOTAGS=$(GOTAGS) \
		$(WINDOWS_CC_IMAGE)
```

Common variables to consider: `GOEXPERIMENT`, `GOTAGS`, `CGO_CFLAGS`, `CGO_LDFLAGS`.

## Claude Prompts

Copy these prompts to help Claude migrate your project to use these workflows.

### Migrate Existing Project

```
Migrate this Go project to use bennypowers/go-release-workflows.

Requirements:
1. Add Makefile targets for: linux-x64, linux-arm64, darwin-x64, darwin-arm64, win32-x64, win32-arm64
2. Output binaries to dist/bin/<binary-name>-<platform>[.exe]
3. Windows targets should use podman with Containerfile.windows
4. Create .github/workflows/release.yml using the shared build-binaries.yml workflow
5. Create .github/workflows/ci.yml for PR validation (no release-tag = artifacts only)

Binary name: <YOUR_BINARY_NAME>
npm package (if applicable): <@scope/package-name or "none">

Read the existing Makefile and workflows first, then show me the changes needed.
```

### Add npm Publishing

```
Add npm publishing to this project using bennypowers/go-release-workflows.

Requirements:
1. Create npm/ directory with package.json for the main wrapper package
2. The main package should have optionalDependencies for all 6 platform packages
3. Add a postinstall script or bin wrapper that finds and uses the correct platform binary
4. Update .github/workflows/release.yml to call npm-publish.yml after build-binaries.yml

npm package name: <@scope/package-name>
Binary name: <YOUR_BINARY_NAME>
```

### Create Makefile from Scratch

```
Create a Makefile for cross-compiling this Go project with CGO enabled.

Requirements per bennypowers/go-release-workflows contract:
- Targets: linux-x64, linux-arm64, darwin-x64, darwin-arm64, win32-x64, win32-arm64
- Output: dist/bin/<binary-name>-<platform>[.exe]
- Linux ARM64 uses CC=aarch64-linux-gnu-gcc
- Windows targets use podman with Containerfile.windows (fetched from shared workflow)
- Use -ldflags="-s -w" for smaller binaries

Binary name: <YOUR_BINARY_NAME>
```

### Validate Migration

```
Create a migration validation workflow to compare outputs from my existing build
workflow against bennypowers/go-release-workflows before switching.

The workflow should:
1. Run both builds in parallel (existing and new)
2. Download all artifacts from both
3. Use the validate-build action to compare hash, size, and architecture
4. Use strict mode to fail if binaries don't match exactly

My existing workflow produces binaries at: <path/to/binaries>
My binary name: <YOUR_BINARY_NAME>
```

### Debug Build Failure

```
The build is failing when using bennypowers/go-release-workflows.

Error output:
<paste error here>

Platform: <which platform failed>
Binary name: <YOUR_BINARY_NAME>

Check:
1. Does my Makefile have the correct target name?
2. Does the output go to dist/bin/<binary-name>-<platform>[.exe]?
3. For Windows: is Containerfile.windows present or being fetched correctly?
4. For Linux ARM64: is gcc-aarch64-linux-gnu available?
```

## License

GPL-3.0 - See [LICENSE](LICENSE) for details.
