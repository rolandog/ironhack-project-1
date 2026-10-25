# shellcheck shell=bash
# Sourced by scripts/rg-*.sh. The caller sets PROG (and VERSION for version()).
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

# version --- print "<prog> <version>"; fails loudly if the caller forgot VERSION
version() { printf '%s %s\n' "$PROG" "${VERSION:?VERSION is not set}"; }

# banner TEXT --- milestone banner: figlet or toilet when installed, else plain echo
banner() {
  local w=${COLUMNS:-80}
  if command -v figlet >/dev/null 2>&1; then
    figlet -w "$w" "$*"
  elif command -v toilet >/dev/null 2>&1; then
    toilet -w "$w" "$*"
  else
    printf '=== %s ===\n' "$*"
  fi
}
