#!/usr/bin/env bash
# rg-m2-cleanup.sh -- destroy the M2 infrastructure and check nothing billable is left
set -euo pipefail
set -C

readonly PROGRAM=${0##*/}
readonly VERSION=1.0
auto=no

usage() {
  cat <<EOF
Usage: $PROGRAM [OPTION]...
Run tofu destroy in infra/ and list leftover NAT gateways, addresses and
instances.  The state bucket from the bootstrap script is kept.

  --yes      do not ask for confirmation
  --help     display this help and exit
  --version  output version information and exit
EOF
}

for arg; do
  case $arg in
    --help)    usage; exit 0 ;;
    --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    --yes)     auto=yes ;;
    *)         usage >&2; printf "%s: error: unrecognized option '%s'\n" "$PROGRAM" "$arg" >&2; exit 1 ;;
  esac
done

cd -- "$(dirname -- "$0")/.."

if [[ $auto == yes ]]; then
  tofu -chdir=infra destroy -auto-approve
else
  tofu -chdir=infra destroy
fi
rm -f ansible/known_hosts

printf '\n== leftovers (each table should be empty) ==\n'
aws ec2 describe-nat-gateways \
  --filter 'Name=tag:Name,Values=rg-nat' 'Name=state,Values=pending,available,deleting' \
  --query 'NatGateways[].[NatGatewayId,State]' --output table
aws ec2 describe-addresses --filters 'Name=tag:Name,Values=rg-nat-eip' \
  --query 'Addresses[].[AllocationId,PublicIp]' --output table
aws ec2 describe-instances \
  --filters 'Name=tag:Name,Values=rg-vm*' 'Name=instance-state-name,Values=pending,running,stopping,stopped' \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table
