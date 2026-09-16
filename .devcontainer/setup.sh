#!/usr/bin/env bash
set -euo pipefail

export ASDF_DIR="/root/.asdf"
export ASDF_DATA_DIR="/root/.asdf"
. "$ASDF_DIR/asdf.sh"

printf 'erlang 27.3\nelixir 1.20.1-otp-27\n' > /root/.tool-versions
asdf install erlang 27.3
asdf install elixir 1.20.1-otp-27
asdf reshim
asdf global erlang 27.3
asdf global elixir 1.20.1-otp-27

mix local.hex --force
mix local.rebar --force

cd /workspace/apps/demo_berlin_districts
mix setup
npm install

cd /workspace/apps/demo_gsd_tracker
MIX_ENV=dev mix ecto.create
MIX_ENV=dev mix ecto.migrate
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
