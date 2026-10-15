#!/usr/bin/env bash

owner=rolandog
repo=ironhack-project-1

# one milestone per release, so closing it matches tagging it
while IFS='|' read -r title desc; do
  sleep 1
  gcli milestones create -o "$owner" -r "$repo" -t "$title" -d "$desc"
done <<'EOF'
M0 Setup|Fork, board, .gitignore, README skeleton
M1 Images + local compose (v0.1.0)|Parts 1.1-1.3, multi-arch images
M2 Terraform infra (v0.2.0)|Part 2, VPC, SGs, EC2, S3 state
M3 Ansible deploy (v0.3.0)|Part 3, app working end to end
M4 Hardening + add-ons|Proper SGs, postgres volume, S3 bootstrap
M5 Final Sprint Review (v1.0.0)|Docs, screenshots, demo, cleanup
Backlog: ALB / monitoring|Add-ons after the demo
EOF

# name|colour|description
while IFS='|' read -r name colour desc; do
  sleep 1
  gcli labels create -o "$owner" -r "$repo" -n "$name" -c "$colour" -d "$desc"
done <<'EOF'
terraform|7B42BC|Infrastructure as code
ansible|EE0000|Configuration management
docker|0DB7ED|Images and compose
security|D93F0B|Security groups and secrets
docs|0075CA|README, screenshots, slides
EOF
