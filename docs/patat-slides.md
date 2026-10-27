---
title: 'Voting app on EKS'
author: 'rolandog'
patat:
  wrap: true
  margins:
    left: 2
    right: 2
  speakerNotes:
    file: /tmp/rg-notes.txt
  theme:
    header: [bold, 'rgb#bd93f9']
    strong: [bold, 'rgb#ff79c6']
    emph: [italic, 'rgb#f1fa8c']
    code: ['rgb#50fa7b']
    codeBlock: []
    bulletList: ['rgb#8be9fd']
    borders: ['rgb#6272a4']
    tableHeader: [bold, 'rgb#bd93f9']
    tableSeparator: ['rgb#6272a4']
    linkTarget: ['rgb#8be9fd']
...

## Voting app on EKS: what changed since Project 1

<!-- NOTES [0:00, 15s]
Hi everyone. You know the voting app, so I'll skip it. This is how I got
it onto Kubernetes with a pipeline: my decisions, where I got stuck, and
what I want to get better at.
-->

Project 2: EKS, Gateway API, ECR and GitHub Actions

Ironhack DevOps Bootcamp

**rolandog** | release 1.2.0 in progress

Base: teacher's repo plus upstream PR #28 (Martin)

## What we did differently

<!-- NOTES [0:15, 39s]
Project 1 was three Debian hosts and Ansible. This time it's EKS, built
with OpenTofu. My rule was free software wherever possible: OpenTofu,
Podman, Envoy Gateway, git-flow. The lab suggested NGINX Ingress, but its
maintenance ended in March, so I used the Gateway API with Envoy. The
registry is where I gave ground: ECR instead of Docker Hub, because
everything else already lives in AWS. Harbor, a CNCF-graduated registry,
is the free alternative I haven't tried yet. The cluster is destroyed
every night to save money, so scripted rebuilds matter.
-->

| | Project 1 | Project 2 |
|---|---|---|
| Platform | 3 Debian hosts, Ansible, Quadlet | EKS 1.35, 2 x t4g.medium (arm64), OpenTofu |
| Entry point | public IP on one host | NLB + Envoy Gateway (Gateway API), Route 53 |
| Registry | Docker Hub | ECR: immutable tags, scan on push |
| Delivery | scripts run by hand | GitHub Actions + OIDC, no stored AWS keys |
| Cost | always on, nano hosts | destroyed nightly, about 20 min to rebuild |

- Envoy Gateway instead of the lab's NGINX Ingress: ingress-nginx was retired in March 2026

## System context

<!-- NOTES [0:54, 15s]
Two changes: Docker Hub became ECR, and GitHub Actions is real now.
Upfront: AWS and GitHub aren't free software, so FLOSS everywhere isn't
true here. It holds for my tooling and the workloads in the cluster.
-->

```text
         o    Voter [Person]                                 o    Operator [Person]
        /|\   Casts votes, views                            /|\   Provisions, deploys
        / \   live results                                  / \
         |                                                   ║
         |  votes, views results                             ║  git push
         |                                                   ║
         v                                                   v
+--------------------------------+                  +~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~+
| Voting App                     |                  | GitHub Actions                 |
| [Software System]              |  set image       | [External System]              |
| Cats vs Dogs poll with         |<=================| Builds, pushes images to ECR,  |
| live results                   |                  | deploys on main (pending)      |
+--------------------------------+                  +~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~+
                  |                                                   ║
                  |  runs on                                          ║  pushes images
                  v                                                   v
+~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~+                  +~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~+
| AWS: EKS, NLB, EBS, Route 53   |                  | AWS ECR                        |
| [External System]              |  pulls images    | [External System]              |
| Managed Kubernetes,            |----------------->| Private image registry,        |
| load balancer, volumes         |                  | immutable tags, scan on push   |
+~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~+                  +~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~+
```

Wavy edge = external system. Double line = build or deploy time.

## Containers in namespace rg-app

<!-- NOTES [1:09, 30s]
Same five services. What's new is the way in: browser, load balancer,
Envoy, then vote or result. Envoy rewrites /vote to the root, because the
Flask app serves from there. Postgres sits on an EBS volume, which is why
teardown deletes volumes explicitly. Redis is the piece I'd like to swap
for Valkey, the BSD-licensed Linux Foundation fork. I haven't tested it,
so I can't promise it's a drop-in.
-->

```text
                                              o    Voter [Person]
                                             /|\   Web browser
                                             / \
                                               |  HTTP port 80 via AWS NLB
                                               v
+==================================================================================================+
║ Voting App [Software System]   namespace rg-app on EKS 1.35                                      ║
║                                                                                                  ║
║         +------------------------------------------------------------------------------+         ║
║         |▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒|         ║
║         | Envoy Proxy [Envoy Gateway v1.9.2]                                           |         ║
║         | HTTPRoutes /vote and /result, behind the AWS NLB                             |         ║
║         +------------------------------------------------------------------------------+         ║
║                |  /vote (rewrite to /)             /result, /result/socket.io  |                 ║
║                v                                                               v                 ║
║ +--------------------------------+                            +--------------------------------+ ║
║ | vote                           |                            | result                         | ║
║ | [Python, Flask, gunicorn]      |                            | [Node.js, Socket.IO]           | ║
║ | Ballot page, port 80           |                            | Live tally, PORT planned 8080  | ║
║ | uid 10001                      |                            | uid 1000                       | ║
║ +--------------------------------+                            +--------------------------------+ ║
║                |  rpush votes, TCP 6379                 reads votes, TCP 5432  |                 ║
║                v                                                               v                 ║
║ +--------------------------------+     +----------------+     +--------------------------------+ ║
║ | redis                          |     | worker         |     | db                             | ║
║ +--------------------------------+<----| [.NET 10]      |---->+--------------------------------+ ║
║ | [Data store: Redis 8.10]       |     | Moves votes    |     | [Data store: PostgreSQL 18]    | ║
║ | Queue of pending votes         |     | redis -> db    |     | votes table on PVC rg-gp3      | ║
║ +--------------------------------+     +----------------+     +--------------------------------+ ║
+==================================================================================================+
```

## Pipeline: the branch decides

<!-- NOTES [1:39, 39s]
The branch decides what happens. A pull request only proves the images
build. A push to develop builds amd64 and arm64 with Podman, checks each
ELF header, and pushes an immutable tag to ECR. A push to main does the
same, then deploys. No AWS keys are stored in GitHub: each job assumes an
IAM role through OIDC. The wrinkle is that the cluster API only allows my
IP, so the deploy job adds the runner's address and always restores the
list. Honest status: pushing works; the deploy job has never run.
-->

```text
pull request -> build amd64, no push
develop      -> build amd64+arm64 -> ELF check -> ECR  tag 1.2.0-dev.N (immutable)
main         -> same, tag 1.2.0 -> deploy job (not yet run):
                open API allow-list to the runner /32 -> kubectl set image
                -> rollout status -> restore the allow-list (always)
auth         -> GitHub OIDC -> one IAM role per job, no stored AWS keys
```

- Push role: develop and main. Deploy role: main only, Edit on namespace `rg-app`
- Tags are never reused; the registry digest is verified after every push
- Images are pinned as `tag@digest`

## Challenges and solutions

<!-- NOTES [2:18, 35s]
Two stories. First, the load balancer: with one Envoy pod and cross-zone
off, it sent traffic to a zone with no proxy. Two replicas across zones
fixed that. Second, destroy hung on leftover network interfaces, so
teardown now deletes the Gateway first, waits, then runs tofu destroy.
The last row is live right now: Podman prints build progress on stdout,
and it ended up in the file GitHub reads outputs from. Shell error
handling is a skill I need to sharpen.
-->

| Challenge | Solution |
|---|---|
| NLB targets unhealthy, intermittent failures | 2 Envoy replicas spread over zones; test each NLB IP |
| VPC delete hung on leftover load balancer ENIs | `rg-down.sh` deletes the Gateway first, waits, then `tofu destroy` |
| Hosted runner cannot reach the API (allow-list is my /32) | deploy job opens its own /32 and restores the list |
| OIDC `sub` claim uses owner and repo IDs on new repos | printed the claim, trust policy uses the IDs |
| CI output step broken by podman progress lines | keep only pin lines, add `pipefail` (fix pending) |

## Requirements: aimed, reached, open

<!-- NOTES [2:53, 32s]
Row by row. Goals one and two, the cluster and the services, are done
and verified. Goal three has two halves: build and push works on both
architectures, with a bug in the summary step; deploy from CI is written
but not run, because the deploy role only trusts main. Hardening is
partial: non-root images, no database password in git, but security
contexts are still open. I'd rather show the gaps than hide them.
-->

| Goal | Aimed for | Status |
|---|---|---|
| 1. Secure, scalable EKS | OpenTofu, restricted API, signed commits | **Done**: EKS 1.35, API on my /32 only, checkov 0 failed |
| 2. Deploy the 5 services | manifests, /vote and /result routes | **Done**: HTTP 200 on both NLB IPs, Postgres on EBS gp3 |
| 3a. Build and push | multi-arch images to a registry | **Done on develop**: ECR, amd64+arm64, ELF-checked; summary step has a bug |
| 3b. Deploy from CI | `kubectl` on push to main | **Not yet run**: written, waits for release 1.2.0 |
| Hardening (#71) | non-root, secrets, securityContext | **Partial**: app images non-root, DB password never in git |
| Docs | README, C4 diagrams, slides | **Partial**: diagrams done, README open |

## Gitflow: worth it, but cumbersome

<!-- NOTES [3:25, 28s]
Gitflow has a lot of edge cases. I stacked a branch on an unmerged pull
request and couldn't push. A branch merged by PR must not also be
finished with git flow. And I can't test the deploy until a release
exists. But main stays releasable while the mess happens elsewhere, and
releases get signed tags. For one person it's ceremony, but a fair trade.
-->

- Good: `main` stays releasable, the mess lives on `feature/*`, releases get signed tags
- Cumbersome: many edge cases
  - branch stacked on an unmerged PR: could not push
  - merged by PR **or** `git flow feature finish`, never both
  - deploy role trusts `main`: CI deploy cannot be tested before a release
- Verdict: ceremony for one person, but it protects `main`

## Backlog

<!-- NOTES [3:53, 22s]
Next: fix the summary step, cut 1.2.0, run the first CI deploy. Then
hardening and CodeQL alerts. Known gaps: manifests still pull from Docker
Hub, the site is plain HTTP, and there's an intermittent timeout on vote
I'm still investigating. TLS and security contexts are areas I want to
learn properly.
-->

- Now: fix the publish summary step, release 1.2.0, first CI deploy (#87)
- Next: #71 hardening (securityContext, secrets), CodeQL alerts #65 to #68, README
- Gap: manifests still pull from Docker Hub until the ECR digests are pinned
- Gap: the site is plain HTTP, no TLS on the NLB yet
- Gap: intermittent `/vote/` timeout (about 1 in 6 in my test, cause open)

## Demo

<!-- NOTES [4:15, 60s]
0:00 to 0:20: the terminal already shows rg-demo.sh output, so I don't
wait for it. Point at: 2 arm64 nodes, 5 workloads Ready, HTTP 200 on
/vote/ and /result/, newest ECR tag 1.2.0-dev.4, 2 allow-list entries
(my IPs). Say: the image pins still show Docker Hub, that's the gap on
the backlog slide.
0:20 to 0:50: browser, two tabs. Cast a vote, switch to /result/, the
count changes live. If the vote page hangs, reload once and say it's the
known timeout.
0:50 to 1:00: the Actions page: which run is green, which step is still
red, and that the deploy job is waiting for the release.
-->

```bash
scripts/rg-demo.sh
```

- Terminal: nodes, workloads, image pins, HTTP 200 per path, CI runs
- Browser: vote at `http://app.p2.ih.rolan.dog/vote/`, watch `/result/`

## Thank you

<!-- NOTES [5:15, hand-over]
Thanks. The code, the C4 diagrams and the issues are in the repo; I'm
happy to take questions on the pipeline, the Gateway API choice, or the
things I said I still need to learn.
(not spoken) Stay on this slide while switching. Do NOT tear down after
your own turn: the order is unknown. After the last presenter, run the
teardown (check rg-down.sh --help): the EKS control plane, nodes and the
NLB bill by the hour.
-->

**Voting app on EKS**

rolandog | `github.com/rolandog/ironhack-project-1`

**Questions?**
