# Changelog

## 0.1.0 - 2026-10-15
### Added
- Multi-arch (linux/amd64, linux/arm64) images for vote, result and worker on Docker Hub
- Worker Dockerfile cross-publishes for the target arch instead of emulating .NET
- `docker-compose.rg.yml` running the stack from own images
- Rootless Podman build scripts, README skeleton, `.gitignore`, project tracking
