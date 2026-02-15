# cockpit-networkmanager-halos

**Package**: HaLOS-specific build of Cockpit's NetworkManager module with comprehensive WiFi support

## About

This repository provides the infrastructure to build and deploy cockpit-networkmanager with WiFi features for HaLOS (Hat Labs Operating System). The WiFi features are developed in the `halos-org/cockpit` fork (wifi branch) and packaged here for HaLOS distribution.

## Development

**Quick Start:**
```bash
# Build Docker image (one-time)
./run docker-build

# Build package
./run build

# Deploy to test device
./run deploy

# Full cycle
./run test-cycle
```

**Build System:**
- Docker-based for cross-platform development
- Builds from halos-org/cockpit (wifi branch)
- Generates: `cockpit-networkmanager-halos_VERSION_all.deb`
- Target iteration: < 5 minutes

**Repository Structure:**
```
cockpit-networkmanager-halos/
├── debian/          # Debian packaging
├── docker/          # Build environment
├── scripts/         # Build/deploy helpers
├── run              # Main CLI wrapper
├── Makefile         # Convenience targets
└── README.md        # Documentation
```

## WiFi Features

**Status**: Under development (halos-org/cockpit#1-#10)

**Features (Planned):**
- WiFi network scanning and connection
- WPA2/WPA3 Personal authentication
- Access Point (hotspot) mode
- Simultaneous AP + Client mode

## Build Pipeline

1. Clone halos-org/cockpit (wifi branch)
2. npm install
3. ./build.js networkmanager
4. Package as .deb

## Related Repositories

- **halos-org/cockpit** (wifi branch): WiFi feature implementation
- **halos**: Workspace for HaLOS development

## Git Workflow

Follow PROJECT_PLANNING_GUIDE.md from halos workspace.
