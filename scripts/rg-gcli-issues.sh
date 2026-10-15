#!/usr/bin/env bash
# rg-gcli-issues.sh -- create labels and issues, link them to milestones (gcli 2.3.0)
set -euo pipefail
set -C

readonly PROGRAM=${0##*/}
readonly VERSION=1.0
OWNER=rolandog
REPO=ironhack-project-1
DRY=no
LIMIT=0
SKIP_LABELS=no
tmpdir=

usage() {
  cat <<EOF
Usage: $PROGRAM [OPTION]...
Create labels and issues, attach each issue to its milestone.
Milestones must already exist (run rg-gcli-bootstrap.sh first).

  --owner=OWNER  repository owner (default: $OWNER)
  --repo=REPO    repository name (default: $REPO)
  --dry-run      print what would be created, change nothing
  --skip-labels  do not create labels (they already exist)
  --limit=N      stop after N issues (use 1 to test)
  --help         display this help and exit
  --version      output version information and exit
EOF
}

die() { printf '%s: error: %s\n' "$PROGRAM" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "$PROGRAM" "$*" >&2; }

cleanup() { if [[ -n $tmpdir ]]; then rm -rf -- "$tmpdir"; fi; }
trap cleanup EXIT

for arg; do
  case $arg in
    --help)    usage; exit 0 ;;
    --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    --owner=*) OWNER=${arg#*=} ;;
    --repo=*)  REPO=${arg#*=} ;;
    --dry-run) DRY=yes ;;
    --skip-labels) SKIP_LABELS=yes ;;
    --limit=*) LIMIT=${arg#*=} ;;
    *)         usage >&2; die "unrecognized option '$arg'" ;;
  esac
done

command -v gcli >/dev/null || die "gcli not found"
repo_args=(-o "$OWNER" -r "$REPO")

# titles must match rg-gcli-bootstrap.sh exactly
declare -A MS=(
  [M0]="M0 Setup"
  [M1]="M1 Images + local compose (v0.1.0)"
  [M2]="M2 Terraform infra (v0.2.0)"
  [M3]="M3 Ansible deploy (v0.3.0)"
  [M4]="M4 Hardening + add-ons"
  [M5]="M5 Final Sprint Review (v1.0.0)"
  [BL]="Backlog: ALB / monitoring"
)
declare -A ms_id

# print the first integer field of the last listing line containing title ($1);
# listing layout is unverified, so check with --limit=1 before the full run
id_of() {
  awk -v t="$1" 'index($0, t) {
    for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { id = $i; break }
  } END { if (id != "") print id }'
}

# ---------- resolve milestone ids ----------
if [[ $DRY == no ]]; then
  ms_list=$(gcli milestones "${repo_args[@]}")
  for k in "${!MS[@]}"; do
    ms_id[$k]=$(id_of "${MS[$k]}" <<<"$ms_list")
    # [[ -n ${ms_id[$k]} ]] || die "milestone '${MS[$k]}' not found; run rg-gcli-bootstrap.sh first"
    if [[ -z ${ms_id[$k]} ]]; then
      printf '%s\n' "$ms_list" >&2
      die "milestone '${MS[$k]}' not found; run rg-gcli-bootstrap.sh first"
    fi

  done

  # EDITOR helper: gcli opens it on a temp file; we overwrite with the body
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/${PROGRAM}.XXXXXX")
  helper=$tmpdir/editor.sh
  # >| because noclobber is on and mktemp -d gave us an empty dir, not a file
  printf '#!/bin/sh\nprintf "%%s\\n" "$RG_ISSUE_BODY" >"$1"\n' >|"$helper"
  chmod +x "$helper"
fi

# ---------- labels (failures only warn: they may already exist) ----------
while IFS='|' read -r name colour desc <&3; do
  sleep 1
  [[ -n $name ]] || continue
  if [[ $SKIP_LABELS == yes ]]; then break; fi
  if [[ $DRY == yes ]]; then
    printf 'label: %s\n' "$name"
  elif ! gcli labels create "${repo_args[@]}" -n "$name" -c "$colour" -d "$desc" >/dev/null 2>&1; then
    warn "label '$name' not created (already exists?)"
  fi
done 3<<'EOF'
terraform|7B42BC|Infrastructure as code (OpenTofu)
ansible|EE0000|Configuration management
docker|0DB7ED|Images, compose, containers
security|D93F0B|Security groups, secrets, scanning
docs|0075CA|README, screenshots, slides
tooling|C5DEF5|Local toolchain and automation
gitflow|F9D0C4|Branching, releases, tags
addon|FBCA04|Optional lab add-on
sprint-1|BFD4F2|Sprint 1
sprint-2|BFDADC|Sprint 2
status:todo|EDEDED|Kanban: to do
status:doing|FEF2C0|Kanban: in progress
status:blocked|B60205|Kanban: blocked
EOF

# ---------- helper functions -------------------------------------------
find_issue() {
  gcli issues "${repo_args[@]}" -a -n -1 -s | id_of "$1"
}

# the listing can lag right after a create, so retry before giving up
wait_for_issue() {
  local n i
  for i in 1 2 3 4 5 6; do
    n=$(find_issue "$1") || true
    if [[ -n $n ]]; then printf '%s\n' "$n"; return 0; fi
    sleep 2
  done
  return 1
}

# ---------- issues: MS|state|labels|title|body (\n = newline) ----------
count=0
while IFS='|' read -r key state labels title body <&3; do
  sleep 1
  [[ -n $key ]] || continue
  if (( LIMIT > 0 && count >= LIMIT )); then break; fi
  count=$((count + 1))

  largs=()
  IFS=, read -ra lbl <<<"$labels"
  for l in "${lbl[@]}"; do largs+=(add "$l"); done
  if [[ $state == open ]]; then largs+=(add status:todo); fi

  if [[ $DRY == yes ]]; then
    printf '[%s] (%s) %s  {%s}\n' "$key" "$state" "$title" "$labels"
    continue
  fi

  num=$(find_issue "$title" || true)
  if [[ -n $num ]]; then
    warn "skipping '$title': already exists as #$num"
    continue
  fi

  # gcli 2.3.0 may abort with a double free after the issue was created,
  # so ignore the exit status and poll the listing instead
  RG_ISSUE_BODY=$(printf '%b' "$body") EDITOR=$helper \
    gcli issues create "${repo_args[@]}" --yes "$title" \
    || warn "gcli exited with status $? creating '$title'; waiting for it to appear"
  num=$(wait_for_issue "$title") \
    || die "cannot find issue '$title' after creating it (waited 12 s)"

  gcli issues "${repo_args[@]}" -i "$num" milestone "${ms_id[$key]}"
  gcli issues "${repo_args[@]}" -i "$num" labels "${largs[@]}"
  if [[ $state == closed ]]; then
    gcli issues "${repo_args[@]}" -i "$num" close
  fi
  printf '%s: #%s [%s] %s\n' "$PROGRAM" "$num" "$key" "$title"
  sleep 1
done 3<<'EOF'
M0|closed|gitflow|setup: fork repo and initialise Gitflow|Forked main of the lab repo; main and develop created with git flow init.
M0|closed|security,tooling|setup: GitHub SSH auth and GPG commit signing|SSH authentication key and GPG signing key prepared for GitHub.
M0|closed|tooling,docker|setup: toolchain (rootless Podman, qemu-user-binfmt, OpenTofu)|Podman chosen for local builds; qemu-user-binfmt installed so linux/arm64 images build on amd64; OpenTofu chosen as the Terraform implementation.
M0|closed|security,tooling|setup: access tokens for gcli and podman login|GitHub PAT for gcli; Docker Hub PAT for podman login. Tokens live outside the repo.
M0|closed|docs|decision: stay on GitHub|Codeberg and SourceHut evaluated; their usage policies conflict with the generative-AI assistance used in this project, so GitHub stays for now.
M0|closed|security|security: enable Dependabot alerts and scanning|Malware and vulnerability scanning enabled.
M0|open|security,tooling,sprint-1|setup: add .gitignore and secret guard|Ignore *.tfstate*, .terraform/, backend.hcl, terraform.tfvars, ansible/hosts.ini, *.pem, .env.\nDone when: files generated by the bootstrap and by tofu are ignored by git.
M0|open|gitflow,sprint-1|gitflow: make develop the default branch|Feature PRs target develop; closing keywords only work on the default branch.\nDone when: Settings > Branches shows develop as default.
M0|open|tooling,sprint-1|setup: enable Issues on the fork and run the milestone/label bootstrap|Forks have Issues disabled by default.\nDone when: gcli milestones lists M0-M5 and Backlog.
M0|open|docs,sprint-1|docs: README skeleton|Sections: architecture, prerequisites, how to run, AI-assistance disclosure.\nDone when: README renders with all headings.
M0|open|terraform,tooling,sprint-1|tooling: check tofu version against required_version|providers.tf says >= 1.11. Compare with tofu version and relax to the lowest version supporting use_lockfile if needed.\nDone when: tofu version satisfies the constraint.
M1|open|docker,docs,sprint-1|docker: record ports and env vars per service|vote and result listen on 80; vote needs REDIS_HOST; result needs PG_HOST/PG_USER/PG_PASSWORD/PG_DATABASE; worker needs REDIS_HOST and DB_HOST/DB_USERNAME/DB_PASSWORD/DB_NAME.\nDone when: table committed to README.
M1|open|docker,sprint-1|docker: create public Docker Hub repos vote, result, worker|Public repos mean the EC2 hosts need no registry login.\nDone when: three empty repos exist.
M1|open|docker,sprint-1|docker: build and push multi-arch vote image|podman manifest create; podman build --platform linux/amd64,linux/arm64 --manifest; podman manifest push. Tags 0.1.0 and latest.\nDone when: both tags pushed.
M1|open|docker,sprint-1|docker: build and push multi-arch result image|Same procedure as vote.\nDone when: both tags pushed.
M1|open|docker,sprint-1|docker: build and push worker image|.NET build is slow under emulation; linux/arm64 only is acceptable because EC2 is Graviton.\nDone when: arm64 manifest pushed.
M1|open|docker,sprint-1|docker: verify published manifests list linux/arm64|podman manifest inspect docker.io/USER/IMAGE:0.1.0 for all three images.\nDone when: each lists linux/arm64.
M1|open|docker,sprint-1|docker: compose file using own images|Replace build: entries with image: docker.io/USER/...:0.1.0; use fully qualified names for redis and postgres.\nDone when: compose file committed.
M1|open|docker,sprint-1|docker: local smoke test of the whole stack|Run the compose stack (podman compose or docker-compose on the Podman socket).\nDone when: a vote shows a tick and the count appears in result.
M1|open|gitflow,sprint-1|gitflow: release 0.1.0|Branch release/0.1.0 from develop; CHANGELOG; merge --no-ff into main and develop; tag v0.1.0; close milestone M1.\nDone when: tag v0.1.0 is pushed.
M2|open|terraform,security,sprint-1|terraform: run rg-bootstrap.sh|Creates the Ed25519 key pair rg-keypair, the S3 state bucket and backend.hcl/terraform.tfvars.\nDone when: describe-key-pairs and head-bucket succeed.
M2|open|terraform,sprint-1|terraform: providers.tf, variables.tf and S3 backend with use_lockfile|tofu init -backend-config=backend.hcl.\nDone when: init succeeds and the state bucket is the backend.
M2|open|terraform,sprint-1|terraform: VPC, subnets, IGW, NAT and route tables|One public and two private subnets, one AZ, NAT for private egress.\nDone when: tofu plan shows the network resources.
M2|open|terraform,security,sprint-1|terraform: security groups with separate rule resources|Postgres 5432 must allow both the backend SG (worker) and the frontend SG (result). Redis 6379 from frontend only. SSH to private hosts only from the frontend SG.\nDone when: plan shows aws_vpc_security_group_*_rule resources.
M2|open|terraform,sprint-1|terraform: three instances on the resolved Debian 13 arm64 AMI|t4g.nano, data source lookup, owner 136693071363.\nDone when: resolved AMI name checked against the plain release naming.
M2|open|terraform,ansible,sprint-1|terraform: outputs and generated ansible/hosts.ini|Bastion public IP, private IPs and URLs as outputs; hosts.ini written by local_file.\nDone when: hosts.ini appears after apply.
M2|open|terraform,docs,sprint-1|terraform: plan and apply, capture screenshots|Checklist items 2-4: lockfile in S3, plan summary, apply complete with outputs.\nDone when: screenshots saved.
M2|open|terraform,docs,sprint-1|terraform: run verification commands, capture screenshots|Checklist items 5-8: VPC/subnets/NAT, instances running, SG rules, tfstate in S3.\nDone when: screenshots saved.
M2|open|gitflow,sprint-1|gitflow: release 0.2.0|Branch release/0.2.0 from develop; CHANGELOG; merge --no-ff into main and develop; tag v0.2.0; close milestone M2.\nDone when: tag v0.2.0 is pushed.
M3|open|ansible,docker,sprint-2|decision: container runtime on EC2 (docker.io or podman)|docker.io keeps community.docker working; podman needs containers.podman modules and fully qualified image names.\nDone when: decision recorded in README.
M3|open|ansible,sprint-2|ansible: ansible.cfg, inventory and bastion connectivity|ProxyCommand through the frontend; interpreter pinned to /usr/bin/python3.\nDone when: ansible -m ping all returns pong for every host.
M3|open|ansible,sprint-2|ansible: base play (docker, docker group, swap)|t4g.nano has 0.5 GiB RAM, so add a 1 GiB swapfile.\nDone when: play recap shows failed=0 for the three hosts.
M3|open|ansible,docker,sprint-2|ansible: database tier (postgres + volume)|Named volume rg-pgdata; password from RG_DB_PASSWORD.\nDone when: docker ps on rg-vm3 shows db.
M3|open|ansible,docker,sprint-2|ansible: backend tier (redis + worker)|User-defined network so the worker resolves redis by name; worker points to the DB private IP.\nDone when: worker logs show redis and postgres connections.
M3|open|ansible,docker,sprint-2|ansible: frontend tier (vote + result)|vote on 80, result on 8081; vote REDIS_HOST is the backend IP; result PG_HOST is the DB IP.\nDone when: both URLs load.
M3|open|ansible,docs,sprint-2|ansible: connectivity tests, logs and screenshots|Checklist items 9-13: PLAY RECAP, /dev/tcp tests, docker ps on each host, vote tick and result count, worker logs.\nDone when: screenshots saved.
M3|open|ansible,sprint-2|ansible: check worker memory on t4g.nano|If the worker is OOM-killed, set instance_types.backend to t4g.micro.\nDone when: worker stays up for 10 minutes under votes.
M3|open|gitflow,sprint-2|gitflow: release 0.3.0|Branch release/0.3.0 from develop; pin image tags to 0.3.0 or 0.1.0 images in vars; merge --no-ff into main and develop; tag v0.3.0; close milestone M3.\nDone when: tag v0.3.0 is pushed.
M4|open|security,addon,sprint-2|security: audit security groups|Redis is 6379 (the lab text says 6739). Backend and DB accept SSH only from the frontend SG; no 0.0.0.0/0 ingress except 80/8081 and admin SSH.\nDone when: describe-security-group-rules reviewed for all three SGs.
M4|open|security,sprint-2|security: triage Dependabot alerts|Review alerts for vote, result and worker dependencies; fix or document.\nDone when: no unreviewed alerts.
M4|open|addon,docker,sprint-2|addon: verify postgres volume persistence|docker rm -f db on rg-vm3, re-run the playbook, check votes remain.\nDone when: votes survive.
M4|open|addon,terraform,sprint-2|addon: provision the state bucket with its own Terraform folder|Separate folder creating the S3 bucket (versioning, public access block); lockfile replaces DynamoDB.\nDone when: bucket managed by tofu.
M4|open|addon,ansible,sprint-2|addon (optional): individual bastion host|Dedicated bastion; frontend stops being a jump host and only accepts SSH from the bastion.\nDone when: ansible runs from the bastion.
M5|open|docs,sprint-2|docs: assemble the 14 screenshots|Use the screenshot checklist; one folder per section.\nDone when: all 14 captured.
M5|open|docs,sprint-2|docs: finalise README|Architecture diagram, run order, cost warning about the NAT gateway, AI-assistance disclosure.\nDone when: a fresh clone can follow the README.
M5|open|docs,sprint-2|docs: 15-minute presentation and demo script|Infra (plan, subnets, EC2), Ansible approach, live vote and result.\nDone when: slides done.
M5|open|docs,sprint-2|demo: rehearse end to end|Full apply, playbook and demo from scratch, timed.\nDone when: run completes in the time budget.
M5|open|terraform,sprint-2|ops: run rg-cleanup.sh and verify nothing billable remains|Check NAT gateways, EIPs and instances.\nDone when: verification commands return empty.
M5|open|gitflow,sprint-2|gitflow: release 1.0.0|Branch release/1.0.0 from develop; CHANGELOG; merge --no-ff into main and develop; tag v1.0.0; close milestone M5.\nDone when: tag v1.0.0 is pushed.
M5|open|docs,addon,sprint-2|docs: LinkedIn post (optional)|Write after the public repo is clean of secrets.\nDone when: posted.
BL|open|addon,terraform|addon: ALB with /vote and /result path routing|Two AZs, target groups, instances split per service.\nDone when: both paths work through the ALB.
BL|open|addon,ansible|addon: CloudWatch logs, metrics and alarms|Agent for container logs, CPU/memory metrics, e-mail alarms.\nDone when: alarm fires on a test.
BL|open|addon,docker|addon: run the apps locally without containers|Python, Node.js and .NET 8 runtimes locally; Redis and Postgres in containers.\nDone when: all five services run.
EOF
