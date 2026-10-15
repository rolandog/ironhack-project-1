# Changelog

## 0.2.0 - 2026-10-15
### Added
- OpenTofu infrastructure: VPC, 3 subnets, NAT gateway, 3 security groups
  with separate SG-to-SG rule resources
- 3 x t4g.nano Debian 13 arm64 instances (AMI via data source), IMDSv2
  required, encrypted EBS, generated `ansible/hosts.ini`
- S3 remote state with native lockfile
- `rg-m2-verify.sh` and `rg-m2-cleanup.sh`
- checkov scan: 94 passed, 0 failed, 10 skipped (each skip documented)

## 0.1.0 - 2026-10-15
### Added
- Multi-arch (linux/amd64, linux/arm64) images for vote, result and worker on Docker Hub
- Worker Dockerfile cross-publishes for the target arch instead of emulating .NET
- `docker-compose.rg.yml` running the stack from own images
- Rootless Podman build scripts, README skeleton, `.gitignore`, project tracking
