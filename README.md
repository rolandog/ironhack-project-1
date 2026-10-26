<!-- © 2024 | Ironhack -->
<!-- © 2026 | Rolando Garza -->

---

# Ironhack Project 1 — Multi-stack voting app on AWS

Polyglot voting application (Python, Node.js, .NET, Redis, PostgreSQL)
deployed on AWS Graviton instances with OpenTofu and Ansible.

> **AI-assistance disclosure:** this project was developed with the help of
> generative AI (code review, scripts, documentation drafts). All output was
> reviewed and tested by the author.

## Architecture

| Service | Language | Listens | Env vars (image default) |
|---|---|---|---|
| vote | Python | 80 | `REDIS_HOST` (`redis`), `REDIS_PORT` (`6379`), `VOTING_MODE` (`every-click` or `one-per-voter`) |
| result | Node.js | 80 (8081 on host) | `PG_HOST` (`db`), `PG_PORT` (`5432`), `PG_USER`/`PG_DATABASE` (`postgres`), `PG_PASSWORD` (no image default; the code falls back to `postgres`) |
| worker | .NET | none | `REDIS_HOST` (`redis`), `DB_HOST` (`db`), `DB_USERNAME`/`DB_NAME` (`postgres`), `DB_PASSWORD` (no image default; the code falls back to `postgres`), `VOTING_MODE` (`every-click`) |
| redis | none | 6379 | none |
| postgres | none | 5432 | `POSTGRES_USER`, `POSTGRES_PASSWORD` (required by the image) |

Defaults match the compose service names. On EC2, override `REDIS_HOST` and `DB_HOST` with the private IPs.

**Database password.** No password is stored in git. Create one outside the
repository; use hex, because `result` builds a connection URL from it:

```sh
install -d -m 700 ~/.config/rg
[ -e ~/.config/rg/p2.env ] || { umask 077; printf 'RG_DB_PASSWORD=%s\n' "$(openssl rand -hex 24)" >~/.config/rg/p2.env; }
set -a; . ~/.config/rg/p2.env; set +a
```

Ansible reads `RG_DB_PASSWORD` and writes it to a 0600 file on each host.
`podman compose` reads `DB_PASSWORD` (for example `DB_PASSWORD=$RG_DB_PASSWORD`).
Postgres applies the password only when it first creates its data directory,
so change it only together with a fresh data volume.

Diagrams follow the [C4 model](https://c4model.com/diagrams). Sources are ASCII art in `docs/diagrams/*.txt`; run `make` to regenerate the SVGs (needs [aasvg](https://www.npmjs.com/package/aasvg)).

### System context

![System context: a voter and an operator use the Voting App, which runs on AWS and pulls images from Docker Hub; GitHub Actions deploys it.](docs/diagrams/c4-01-context.svg)

<details><summary>Key</summary>

![Key for the system context diagram](docs/diagrams/c4-01-context-key.svg)

</details>

### Containers

![Containers: Envoy routes /vote and /result to the vote and result apps; vote writes to redis, the worker moves votes from redis to PostgreSQL, result reads PostgreSQL.](docs/diagrams/c4-02-containers.svg)

<details><summary>Key</summary>

![Key for the container diagram](docs/diagrams/c4-02-containers-key.svg)

</details>


## Repository layout

```text
vote/ result/ worker/   application sources (from the lab repository)
infra/                  OpenTofu: providers.tf variables.tf main.tf outputs.tf
ansible/                ansible.cfg hosts.ini (generated) playbook.yml
scripts/                bootstrap, gcli and cleanup scripts
docs/                   screenshots and presentation
```

## Prerequisites

- Debian 13 VM (KVM/libvirt) with: Podman (rootless), `qemu-user-binfmt`,
  OpenTofu >= 1.10, Ansible, AWS CLI v2, `gcli`
- AWS credentials for `eu-central-1`
- Docker Hub account and access token (`podman login docker.io`)
- `containers.podman` from ansible-galaxy; install with:
  ```sh
  ansible-galaxy collection install -r requirements.yml
  ```
- `pipx`, install with:
  ```sh
  sudo apt install pipx
  ```
- `ansible` and `checkov`, installable via:
  ```sh
  cat requirements.txt | xargs pipx install
  ```

## How to run

1. **Bootstrap** (key pair, S3 state bucket, `backend.hcl`, `terraform.tfvars`):
   ```sh
   tofu -chdir=bootstrap init && tofu -chdir=bootstrap apply   # once per account
   tofu -chdir=infra init -reconfigure -backend-config=backend.hcl
   ```
2. **Build, publish and verify images** (multi-arch with `podman manifest`; see [docs/images.md](docs/images.md)):
   ```sh
   scripts/rg-build-images.sh --user=<hub-user> --tag=X.Y.Z --push
   ```
   The script refuses to overwrite an existing tag, checks both platforms and
   prints the `*_IMAGE_TAG=tag@sha256:...` lines to paste into `.env.example`,
   `.env` and `ansible/site.yml`.
3. **Provision infrastructure:**
   ```
   tofu -chdir=infra plan
   tofu -chdir=infra apply
   ```
4. **Deploy with Ansible:**
   ```
   cd ansible
   ansible-playbook --check site.yml
   ansible-playbook site.yml
   ```
5. **Try it:** open `http://<frontend-ip>` (vote) and `http://<frontend-ip>:8081` (result)
6. **Tear down:**:
   ```
   ./scripts/rg-m2-cleanup.sh
   ./scripts/rg-m1-cleanup.sh
   ```


## Verification

`<AWS CLI commands and expected output; link to screenshots in docs/>`

## Project workflow

- Gitflow: `main`, `develop`, `feature/*`, `release/*`, `hotfix/*`
- One GitHub milestone per release (M1 = v0.1.0, M2 = v0.2.0, M3 = v0.3.0, M5 = v1.0.0)
- Issues carry `status:todo` / `status:doing` / `status:blocked` labels; closed = done

## Cost warning

The NAT gateway bills hourly while it exists.  Run the cleanup script after
every session and verify nothing billable remains.

## Credits and license

Based on the Ironhack voting-app lab: https://github.com/Pokfinner/ironhack-project-1.  License: Apache-2.0 license.
