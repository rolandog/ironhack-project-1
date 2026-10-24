# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-10-24
### Added
- `scripts/rg-code-scanning.sh` lists CodeQL alerts grouped by rule and can
  file one issue per rule; it fails on API errors instead of reporting no alerts

### Changed
- Updated the patat presentation slides (`docs/patat-slides.md`)

### Security
- Five CodeQL alerts are open and tracked as issues #64 to #68; fixes are
  planned for 1.x, after the upstream changes are merged

## [0.4.1] - 2026-10-19
### Fixed
- Correct the Postgres data path for Postgres 18 compatibility

## [0.4.0] - 2026-10-18
### Added
- `bootstrap/` OpenTofu folder (local state) that manages the S3 state bucket
  `tf-state-<ACCOUNT_ID>-eu-central-1`: versioning, SSE-S3 encryption, public
  access block, a lifecycle rule that expires old state versions after 90
  days, and `prevent_destroy`
- `bootstrap/` writes `infra/backend.hcl` and the committed
  `infra/backend.hcl.example` (account ID masked), so the backend settings
  cannot drift from the bucket
- Locking uses `use_lockfile = true` (native S3 locking); the DynamoDB table
  from the add-on spec is omitted on purpose
- `.env.example` documents every pinned image tag and `sha256` digest; the
  digests match the images running on the hosts
- Security group audit: ingress and egress, IPv4 and IPv6, public IPs, and
  negative port tests from outside (5432 and 6379 closed)
- Runtime check of the dependency versions installed in the `result`
  container (`podman exec result node -p ...`)
- End-to-end check in `scripts/rg-m3-verify.sh`: cast a vote, read it back
  from Postgres

### Changed
- Backend config is now a partial configuration: `backend "s3" {}` plus
  `tofu -chdir=infra init -reconfigure -backend-config=backend.hcl`
- Every deployed image is pinned by tag and index digest (multi-arch:
  linux/amd64 and linux/arm64):
  `vote:0.1.1`, `result:1.1.0`, `worker:0.1.3`, `postgres:18.6-alpine3.24`,
  `redis:8.10.2-alpine3.23`
- Base images are pinned by digest: `node:24.22.0-slim`,
  `python:3.15.0-slim-trixie`, `dotnet/sdk:10.0.402-alpine3.24` and
  `dotnet/runtime:10.0.13-alpine3.24`
- `result` is `1.1.0`, following its own `1.0.0` version; `vote` and
  `worker` had no earlier version number and keep the `0.x` scheme
- `result`: Node 18 (end-of-life) replaced with Node 24;
  `npm ci --omit=dev --ignore-scripts`; `.npmrc` with `ignore-scripts=true`
  and `min-release-age=18`, with no exclusions
- `worker`: retargeted from .NET 8 to .NET 10 (.NET 8 support ends on
  2026-11-10)
- `vote`: Python 3.15 base image; a vote was cast and read back from Postgres
- Postgres upgraded from 15 to 18.6; the data volume keeps its name but is
  now mounted at `/var/lib/postgresql`, as the 18+ image requires
- Redis pinned to Redis 8 (was the floating `redis:alpine`)
- `site.yml` has a separate tag variable per image, so `vote`, `result` and
  `worker` can move independently

### Removed
- `nodemon` from the production `result` image; it was installed globally,
  unpinned and outside the lockfile
- `rg-sg`, an unused security group left over from an earlier lab (SSH open
  to `0.0.0.0/0`); it was never part of this stack
- The Postgres 15 data: the whole stack, including the state bucket, was
  destroyed and rebuilt, and the database was recreated on Postgres 18
  instead of migrated; the demo votes were discarded

### Fixed
- Worker crash loop after the base image upgrade: the app targeted
  `Microsoft.NETCore.App 8.0.0` and the image carried only 10.0.x
- Postgres crash loop after a floating tag moved to major version 18, which
  refuses data in `/var/lib/postgresql/data`
- Defective images: the `worker:0.1.0` build failed with `Exec format error`
  (amd64 layers in the arm64 image); earlier `vote`, `result` and `worker`
  tags were rebuilt and replaced
- Floating image tags can no longer change the deployed stack between deploys

### Security
- Dependabot: 21 alerts in `result/package-lock.json` (1 critical, 10 high,
  4 medium, 6 low), all npm and runtime scope; none in `vote` or `worker`.
  Fixed by regenerating the lockfile and `overrides` for `proxy-addr`, `qs`
  and `path-to-regexp`; `npm audit --omit=dev` reports 0 vulnerabilities
- `min-release-age=18` is kept without `min-release-age-exclude` entries on
  purpose: no package bypasses the cooldown, which limits exposure to a
  freshly published malicious release
- `result` does not set `trust proxy`, so the critical `proxy-addr`
  advisory was not reachable; it was fixed anyway
- Security groups audited: private tiers accept only security-group
  references (no CIDR); SSH is limited to the admin `/32`; only `rg-vm1`
  has a public IP. Accepted: 80 and 8081 open to the world (public
  endpoints); egress allow-all (apt and image pulls through the NAT)
- Checkov: `infra/` 94 passed, 0 failed, 10 skipped; `bootstrap/` 14 passed,
  0 failed, 3 skipped; each skip has a written reason

### Known issues
- `docker-compose.yml` uses floating tags (`redis:8-alpine`,
  `postgres:18-alpine`, `latest` for `vote`, `result` and `worker`);
  `.env.example` documents the pins but nothing reads it yet
- The database password is the upstream default and is reachable only from
  inside the VPC
- Superseded tags stay on Docker Hub and must not be used: `vote:0.1.0`,
  `result:0.1.0`, `worker:0.1.0` to `0.1.2`
- Redis 8 is licensed under RSALv2, SSPLv1 or AGPLv3; this project uses it
  under the AGPLv3 option. Valkey is a fully free alternative
- The frontend is still the SSH jump host; an individual bastion (#43) is
  moved to the backlog

## [0.3.1] - 2026-10-16
### Added
- Ansible deployment of the voting app onto the three AWS hosts
  (`ansible/ansible.cfg`, `ansible/site.yml`, `ansible/tasks/quadlet.yml`,
  `requirements.yml`); inventory is the `hosts.ini` generated by OpenTofu,
  with the private tiers reached through the frontend as jump host
- Rootless Podman on Debian 13 (Podman 5.4.2), run by a dedicated
  unprivileged `rgapp` user with no sudo; containers are described as
  Quadlet files and managed by systemd user units; lingering keeps them
  running without a login
- Three tiers: Postgres 15 with a named volume (db), Redis and the worker on
  a user-defined network (backend), vote on port 80 and result on port 8081
  (frontend); images pulled anonymously from Docker Hub `rolandog/*`
- 1 GiB swap file on every host (t4g.nano has 512 MiB RAM)
- `scripts/rg-m3-verify.sh`: unit state, containers, memory, HTTP status
  and an end-to-end vote read back from Postgres
- `--no-cache` option in `scripts/rg-build-images.sh`

### Changed
- Container runtime on the hosts is rootless Podman, not Docker (issue #30)
- Worker image is `rolandog/worker:0.1.1`; vote and result stay at `0.1.0`
- Frontend host sets `net.ipv4.ip_unprivileged_port_start=80` so rootless
  containers can publish port 80 (accepted trade-off, documented in code)
- Ansible is installed with `pipx` instead of a virtualenv

### Fixed
- `rolandog/worker:0.1.0`: the arm64 manifest entry held an amd64 runtime
  layer (`exec format error` on Graviton). `worker/Dockerfile` now declares
  the target-platform base in its own first stage. Do not use the 0.1.0 tag.
- Units entering the `failed` state after rapid restarts: every service
  now has `RestartSec=5`
- `rg-m3-verify.sh` reported success when only one of two units was active

### Security
- Containers run rootless as a non-sudo user; no container runs as root
- Database and Redis are reachable only from the security groups that need
  them (rules reference security groups, not CIDRs)

### Known issues
- Redis and Postgres images use floating tags (`redis:alpine`,
  `postgres:15-alpine`); pin digests in M4
- The database password is the upstream default (`postgres`); it is only
  reachable from inside the VPC
- `rolandog/worker:0.1.0` remains on Docker Hub in its broken state

## [0.3.0] - 2026-10-16
### Known issues
- The merge had not taken place before the release was published.

## [0.2.0] - 2026-10-15
### Added
- OpenTofu infrastructure: VPC, 3 subnets, NAT gateway, 3 security groups
  with separate SG-to-SG rule resources
- 3 x t4g.nano Debian 13 arm64 instances (AMI via data source), IMDSv2
  required, encrypted EBS, generated `ansible/hosts.ini`
- S3 remote state with native lockfile
- `rg-m2-verify.sh` and `rg-m2-cleanup.sh`
- checkov scan: 94 passed, 0 failed, 10 skipped (each skip documented)

## [0.1.0] - 2026-10-15
### Added
- Multi-arch (linux/amd64, linux/arm64) images for vote, result and worker on Docker Hub
- Worker Dockerfile cross-publishes for the target arch instead of emulating .NET
- `docker-compose.rg.yml` running the stack from own images
- Rootless Podman build scripts, README skeleton, `.gitignore`, project tracking

[Unreleased]: https://github.com/rolandog/ironhack-project-1/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/rolandog/ironhack-project-1/compare/v0.4.1...v1.0.0
[0.4.1]: https://github.com/rolandog/ironhack-project-1/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/rolandog/ironhack-project-1/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/rolandog/ironhack-project-1/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/rolandog/ironhack-project-1/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/rolandog/ironhack-project-1/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/rolandog/ironhack-project-1/releases/tag/v0.1.0
