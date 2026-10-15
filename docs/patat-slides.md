---
title: 'Polyglot voting app on AWS'
author: 'rolandog'
patat:
  wrap: true
  margins:
    left: 2
    right: 2
  speakerNotes:
    file: /tmp/rg-notes.txt
...

## Goal

<!-- NOTES [0:00, 30s]
Introduce: voting app in three languages (Python vote, Node result,
.NET worker) with Redis and Postgres. Three promises: reproducible,
free software, secure by default. Say: "I will show tooling, security
controls, and live evidence from AWS."
-->

Voting app: Python + Node.js + .NET, Redis, Postgres

- Reproducible: **OpenTofu** + **Ansible**, nothing clicked by hand
- Free software end to end: Debian 13, rootless Podman, OpenTofu
- Security by default, not as an afterthought

## Workflow

<!-- NOTES [0:30, 40s]
Gitflow: main, develop, feature and release branches. Each issue is
tracked in a milestone with status labels. Commits and release tags are
signed; 0.1.0 is already tagged. Mention gcli 2.3.0 crashes (double
free) after creating issues, so my scripts check by listing, not by
exit code. Honest about a tooling limit = credibility.
-->

- **Gitflow**: `main`, `develop`, feature/release branches
- Milestones M0 to M2, 50+ issues, `status:*` labels
- Signed commits and signed release tags (`0.1.0` released)
- `gcli` 2.3.0 crashes -> scripts verify by listing, not exit code

## Images: rootless and multi-arch

<!-- NOTES [1:10, 50s]
Podman runs without a daemon and without root: a compromised build
cannot take over the host. One manifest holds amd64 and arm64, so the
same image runs on my laptop and on Graviton (t4g) instances. The .NET
worker is cross-published on the build host instead of emulated with
QEMU, which was the slow path. The registry token is Read & Write only,
no Delete.
-->

~~~~{.bash}
scripts/rg-build-images.sh --only=vote --push

podman manifest push --all localhost/rg-vote:0.1.0 \
  docker://docker.io/rolandog/vote:0.1.0
~~~~

- Rootless **Podman**, no daemon, no root
- One manifest: `linux/amd64` + `linux/arm64`
- Worker cross-published: no QEMU emulation

## Infrastructure

<!-- NOTES [2:00, 40s]
Draw it in the air: one frontend VM in the public subnet runs vote and
result and is also the jump host. Backend (Redis plus worker) and db
(Postgres) have no public IP; they reach the internet only through the
NAT gateway. Three t4g.nano, Debian 13 arm64. The AMI comes from a data
source with the official Debian owner ID, never hardcoded. State lives
in S3 with a native lockfile.
-->

~~~~
frontend (public)  --->  backend: Redis + worker  --->  db: Postgres
   vm1                        vm2 (private)               vm3 (private)
~~~~

- 1 VPC, 3 subnets, NAT gateway for private egress
- 3 x `t4g.nano`, Debian 13: `debian-13-arm64-20261001-2618`
- State in S3 with `use_lockfile`

## Security: the instance

<!-- NOTES [2:40, 50s]
This is the real code from main.tf. Point at three lines. IMDSv2
required plus hop limit 1: a container on the host cannot reach the
instance metadata. Encrypted root volume. Private subnets: no public IP
at all. Then say: "these are not claims, the verify script shows
HttpTokens = required for all three VMs."
-->

~~~~{.hcl}
resource "aws_instance" "vm" {
  metadata_options {
    http_tokens                 = "required"   # IMDSv2 only
    http_put_response_hop_limit = 1            # containers can't reach it
  }
  root_block_device {
    encrypted = true
  }
  associate_public_ip_address = each.value.public  # frontend only
}
~~~~

## Security: network rules

<!-- NOTES [3:30, 50s]
Key idea: rules reference security groups, not IP ranges. Redis accepts
traffic only from the frontend SG; Postgres only from backend and
frontend SGs. If an IP changes, the rule still holds. SSH from the
internet only from my own /32, only to the frontend. Rules are separate
resources, not inline, so diffs stay clean.
-->

~~~~{.hcl}
resource "aws_vpc_security_group_ingress_rule" "backend_redis" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.frontend.id
  ip_protocol = "tcp"
  from_port   = 6379
  to_port     = 6379
}
~~~~

- 80, 8081: internet. 22: admin `/32` -> frontend only
- 6379: frontend SG. 5432: backend SG + frontend SG
- Default security group locked: no rules

## Static analysis: checkov

<!-- NOTES [4:20, 60s]
I scanned the code with checkov. Fixed what was free: default security
group, EBS optimized, detailed monitoring. What I accepted, I accepted in
writing: the skip sits in the resource and the reason is printed in the
scan output. Say the real numbers: Passed N, Failed 0, Skipped N. Two
skips are a checkov false positive on SG references. Production next
step: ALB + SSM and VPC flow logs.
-->

~~~~{.hcl}
resource "aws_instance" "vm" {
  #checkov:skip=CKV_AWS_88:frontend is the public web endpoint and jump host
  #checkov:skip=CKV2_AWS_41:no role = no credentials to steal
  ...
}
~~~~

~~~~{.bash}
checkov -d infra --framework terraform --compact --quiet
~~~~

- Passed N / Failed 0 / Skipped N: every skip has a reason

## Live evidence

<!-- NOTES [5:20, 60s]
Switch to the second terminal with the verify output (already run).
Point at: NAT available; three instances running, arm64, t4g.nano;
backend and db PublicIp None; HttpTokens required; state object in S3.
Do NOT wait for the command to run live. Hide the admin /32 if you
show the raw security-group table.
-->

~~~~{.bash}
scripts/rg-m2-verify.sh
~~~~

- NAT `available`, 3 instances `running`, `arm64`, `t4g.nano`
- Backend and db: public IP `None`
- Instances: `HttpTokens = required`
- State object in S3

## Next steps

<!-- NOTES [6:20, 40s]
Ansible next: containers on the three hosts through the jump host.
Production hardening: ALB + SSM instead of public SSH, VPC flow logs.
After the talk run scripts/rg-m2-cleanup.sh: the NAT gateway bills per
hour. End with questions.
-->

- Ansible (M3): containers on the 3 hosts, via the jump host
- Production: ALB + SSM instead of public SSH, VPC flow logs
- Teardown: `scripts/rg-m2-cleanup.sh` (NAT gateway bills hourly)

**Questions?**
