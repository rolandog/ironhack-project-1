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
  # optional Dracula palette; needs a 24-bit colour terminal
  theme:
    header: [bold, 'rgb#bd93f9']
    strong: [bold, 'rgb#ff79c6']
    emph: [italic, 'rgb#f1fa8c']
    code: ['rgb#50fa7b']
    codeBlock: ['rgb#50fa7b']
    bulletList: ['rgb#8be9fd']
    borders: ['rgb#6272a4']
    tableHeader: [bold, 'rgb#bd93f9']
    tableSeparator: ['rgb#6272a4']
    linkTarget: ['rgb#8be9fd']
...

## Polyglot voting app on AWS

<!-- NOTES [0:00, 10s]
Greet. One sentence: a voting app written in three languages, deployed
on AWS with free software only, nothing clicked by hand. Four minutes
of slides, then a three-minute live demo.
-->

Rootless Podman, OpenTofu, Ansible on Debian 13

Ironhack DevOps Bootcamp, Week 5

**rolandog** | release 0.4.0

## Project overview

<!-- NOTES [0:10, 25s]
Walk the arrows: vote writes to Redis, the .NET worker moves votes
into Postgres, result reads Postgres. Objectives: practise
infrastructure as code, configuration management, containers, and
security as a default. Say: "I treated the lab as a small production
system."
-->

~~~
vote (Python) --> Redis --> worker (.NET) --> Postgres
result (Node.js) <------------------------------+
~~~

- Objective: deploy and secure it on AWS, reproducibly
- Practised: IaC, config management, containers, Git workflow
- Constraint: Free Software end to end, no root containers

## Implementation: the pipeline

<!-- NOTES [0:35, 25s]
Gitflow with signed commits and release tags. Images are built with
Podman as one manifest holding amd64 and arm64, then pinned by digest
so a tag can never change under me. OpenTofu builds the network and
three hosts, Ansible installs rootless units on them.
-->

~~~
issue -> feature branch -> signed PR -> release tag
build (podman, amd64+arm64) -> Docker Hub, pinned by digest
tofu apply -> VPC + 3 hosts -> ansible -> rootless services
~~~

- Gitflow, signed commits, signed release tags
- Multi-arch manifests; deploys pin tag **and** digest
- Services run as systemd user units (Quadlet), no `sudo`

## Implementation: infrastructure and security

<!-- NOTES [1:00, 35s]
Three t4g.nano hosts on Debian 13 arm64. Only the frontend has a
public IP. Rules reference security groups, not IP ranges: Redis
accepts only the frontend group. IMDSv2 is required with hop limit 1,
and root volumes are encrypted. Checkov: 94 passed, 0 failed, 10
skipped, every skip has a written reason.
-->

~~~{.hcl}
resource "aws_vpc_security_group_ingress_rule" "backend_redis" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.frontend.id
  ip_protocol = "tcp"
  from_port   = 6379
  to_port     = 6379
}
~~~

- Private tiers: no public IP, SG references only, no CIDR
- IMDSv2 required, encrypted volumes, SSH from admin `/32` only
- Checkov: **94 passed / 0 failed / 10 skipped**

## Challenges and solutions

<!-- NOTES [1:35, 30s]
Pick two rows and say them out loud; the rest are on the slide.
Postgres: a floating tag moved to version 18 and the unit restarted
463 times. Dependabot: 21 alerts, all npm in result. Everything is
now pinned and verified by a script that casts a real vote.
-->

| Challenge | Solution |
|---|---|
| 512 MiB hosts | swap + memory check in the verify script |
| Floating tag jumped to Postgres 18: 463 restarts | pin tag + digest; volume at `/var/lib/postgresql` |
| .NET 8 app on .NET 10 runtime | retarget to `net10.0` |
| 21 Dependabot alerts (1 critical) | lockfile, `overrides`, Node 24: audit = 0 |
| Silent restart loops | verify script: units active + end-to-end vote |

## Major obstacle: `Exec format error`

<!-- NOTES [2:05, 40s]
The worker image for arm64 contained amd64 binaries, because the
build reused cached layers from the other platform. It started, died,
and systemd restarted it forever. Fix: multi-stage targets, no-cache
builds with fresh bases, and an ELF check before every push: b7 00 is
arm64, 3e 00 is amd64. In hindsight: write the check on day one and
never reuse a tag.
-->

~~~{.bash}
for p in amd64 arm64; do
  podman run --rm --platform "linux/$p" --entrypoint sh IMAGE \
    -c 'od -An -tx1 -j18 -N2 "$(readlink -f "$(command -v dotnet)")"'
done   # expect amd64: 3e 00   arm64: b7 00
~~~

- Cause: build cache reused across platforms
- Fix: multi-stage target + `--no-cache --pull=always` + ELF check
- Hindsight: verify before push, pin by digest from day one

## Tools and technologies

<!-- NOTES [2:45, 25s]
Why, not what. Debian and Podman because no daemon and no root.
OpenTofu because it is Free Software with native S3 locking. Ansible
because the hosts are tiny and agentless is cheap. Checkov and
Dependabot are the security feedback loop.
-->

| Tool | Why |
|---|---|
| Debian 13, rootless Podman | Free Software, no daemon, no root |
| OpenTofu + S3 `use_lockfile` | reproducible infra, no DynamoDB |
| Ansible | agentless, idempotent config |
| Checkov, Dependabot, `npm audit` | security gates |
| GPG signing, `gcli`, Gitflow | traceable history |

## Project management

<!-- NOTES [3:10, 20s]
Solo project, run like a team: every task is an issue with a status
label in a milestone. 43 of 53 issues closed, none blocked. What
worked: small milestones and one release per milestone. To improve:
the hardening milestone had no release issue, and one closed issue
lacked its done label.
-->

- Solo, run as a Kanban board: `status:*` labels, 7 milestones
- 53 issues: **43 closed**, 6 doing, 4 todo, 0 blocked
- Released 0.1.0 to 0.3.0; 0.4.0 is the hardening release
- Backlog (M7): bastion host, ALB, CloudWatch, run without containers

## Conclusion: objectives met

<!-- NOTES [3:30, 15s]
Say yes to each line. Reproducible: teardown and rebuild worked
twice. Free software: Debian, Podman, OpenTofu. Secure: audit 0,
Checkov 0 failed.
-->

- Reproducible: full teardown and rebuild from code
- Free Software and rootless: no root containers
- Secure: `npm audit` 0, Checkov 0 failed, SG references only

## Insights and open questions

<!-- NOTES [3:45, 15s]
Surprise: most failures came from tags that moved, not from my code.
Honest gaps: I did not build a bastion or ALB, and I discarded the
Postgres 15 data instead of learning pg_upgrade. Invite questions.
-->

- Surprise: moving tags broke more than my own code
- Not done: bastion, ALB, `pg_upgrade` (data was recreated)
- Open: how to wire the `.env.example` pins into compose

## Demo 1: vote

<!-- NOTES [4:00, 60s]
Browser, two tabs. Open vote, cast a vote, switch to result on port
8081 and show the count change. Say which host serves it: only the
frontend is public. If the page is slow, go to the next step and
come back.
-->

- Tab 1: vote page (port 80), cast a vote
- Tab 2: result page (port 8081), count changes

## Demo 2: verify script

<!-- NOTES [5:00, 60s]
Second terminal, output already on screen. Point at: all units
active, image digests match the pins, HTTP 200 on both ports, and the
last section: a vote posted and read back from Postgres. Do NOT wait
for the command to run live.
-->

~~~{.bash}
scripts/rg-m3-verify.sh
~~~

- Units `active` on all 3 hosts, images pinned by digest
- End to end: vote POST -> row in Postgres

## Demo 3: security evidence

<!-- NOTES [6:00, 60s]
Show three outputs: dependency versions inside the running result
container, the Checkov summary, and the security-group table. Hide the
admin /32. Close with: "the claims on my slides are all in this
terminal."
-->

~~~{.bash}
podman exec result node -p ...   # proxy-addr, ws, qs versions
checkov -d infra --framework terraform --compact --quiet
~~~

- Runtime versions = patched ones
- Checkov: 0 failed; private tiers have no public IP

## Thank you

<!-- NOTES [7:00, 10s]
Thank the class and teachers. Name the repo. Then questions. After
the talk, run the cleanup scripts: the NAT gateway bills per hour.
-->

**Polyglot voting app on AWS**

rolandog | `github.com/rolandog/ironhack-project-1`

**Questions?**
