#!/bin/bash

# Start sddm from the user's nix profile (installed by setup-plasma.sh).
# Multiple potential profile locations are resolved so this works across
# nix versions; if nothing exists yet the unit stays inactive and the
# system boots to the console login instead.

set -e

ACE_HOME="${ACE_HOME:-/home/ace}"
BIN=""
for candidate in \
    "$ACE_HOME/.local/state/nix/profile/bin/sddm" \
    "$ACE_HOME/.nix-profile/bin/sddm"; do
    if [[ -x "$candidate" ]]; then
        BIN="$candidate"
        break
    fi
done

if [[ -z "$BIN" ]]; then
    echo "sddm is not installed in the $ACE_HOME nix profile yet." >&2
    echo "run:  sudo -iu ace /usr/lib/arcex/setup-plasma.sh" >&2
    exit 1
fi

exec "$BIN" "$@"