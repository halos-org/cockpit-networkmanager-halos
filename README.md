# cockpit-networkmanager-halos

HaLOS-specific build of Cockpit's NetworkManager module with comprehensive WiFi support.

## Overview

This package provides a replacement for the upstream `cockpit-networkmanager` package with WiFi configuration features under development for HaLOS (Hat Labs Operating System).

**Features (in development):**
- WiFi network scanning and connection management
- WPA2/WPA3 Personal authentication
- Access Point (hotspot) mode configuration
- Simultaneous AP + Client mode support

**Status:** Development infrastructure (Issue #1) - Feature implementation in progress

## Package Information

- **Source**: Built from [halos-org/cockpit](https://github.com/halos-org/cockpit) (wifi branch)
- **Replaces**: cockpit-networkmanager (official package)
- **Architecture**: all (platform-independent JavaScript/HTML/CSS)
- **Dependencies**: cockpit (>= 276), network-manager (>= 1.20)

## Development Workflow

### Prerequisites

- Docker Desktop or Docker Engine
- Git
- SSH access to test device
- Local environment configuration (copy `.env.example` to `.env` and configure)

### Quick Start

```bash
# 1. Build Docker image (first time only)
./run docker-build

# 2. Build package
./run build

# 3. Deploy to test device
./run deploy

# 4. Or do both in one step
./run test-cycle
```

### Development Iteration Cycle

**Fast Local Development** (test uncommitted changes):

```bash
# Edit code in ../cockpit
cd ../cockpit/pkg/networkmanager
# ... make changes to wifi.jsx, network-interface.jsx, etc. ...

# Build and deploy (no commit needed!)
cd ../../cockpit-networkmanager-halos
./run build --local    # Uses ../cockpit source, builds .deb
./run deploy           # Deploys to configured test device, restarts Cockpit

# Test at https://<your-test-device>:9090
```

**Branch Testing** (test pushed GitHub branches):

```bash
# Build from specific branch
./run build --branch fix/wifi-ssid-and-dialog-bugs
./run deploy

# Or build from default wifi branch
./run build
./run deploy
```

**Target iteration time:** < 2 minutes with `--local` (build + deploy)

### Available Commands

Run `./run help` for full command list:

**Build Options:**
- `./run build` - Build from GitHub wifi branch (default)
- `./run build --local` - Build from ../cockpit (local uncommitted changes)
- `./run build --local /path` - Build from custom local path
- `./run build --branch BRANCH` - Build from specific GitHub branch

**Other Commands:**
- `./run deploy` - Deploy package to test device
- `./run test-cycle` - Full build + deploy cycle
- `./run docker-build` - Build Docker image
- `./run clean` - Remove build artifacts

### Pre-commit Hooks

This project uses [lefthook](https://github.com/evilmartians/lefthook) for pre-commit hooks to run lint checks locally before commits.

```bash
# Install lefthook (one-time)
brew install lefthook

# Enable hooks in this repo
./run hooks-install
```

**What it checks:**

- `npm run eslint` - ESLint for TypeScript/JavaScript
- `npm run stylelint` - Stylelint for CSS/SCSS

**Skip hooks when needed:**

```bash
git commit --no-verify -m "WIP: message"
```

### Configuration

Create a `.env` file from the template:

```bash
cp .env.example .env
# Edit .env with your test device details
```

Environment variables in `.env`:

- `TEST_HOST` - Test device hostname (required)
- `TEST_USER` - Test device SSH username (required)

You can also override these via environment variables:

```bash
TEST_HOST=192.168.1.100 TEST_USER=pi ./run deploy
