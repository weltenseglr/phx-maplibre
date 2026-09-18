#!/usr/bin/env bash
set -euo pipefail

export ASDF_DIR="${ASDF_DIR:-/home/vscode/.asdf}"
export ASDF_DATA_DIR="${ASDF_DATA_DIR:-$ASDF_DIR}"
export ASDF_FORCE_PREPEND=yes
export KERL_CONFIGURE_OPTIONS="${KERL_CONFIGURE_OPTIONS:---without-wx}"
. "$ASDF_DIR/asdf.sh"

cd /workspace

for plugin in erlang elixir nodejs; do
  if ! asdf plugin list | grep -qx "$plugin"; then
    # Explicit repositories avoid fetching asdf's entire plugin index.
    asdf plugin add "$plugin" "https://github.com/asdf-vm/asdf-$plugin.git"
  fi
done

asdf install
asdf reshim
