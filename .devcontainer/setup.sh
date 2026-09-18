#!/usr/bin/env bash
set -euo pipefail

export ASDF_DIR="/home/vscode/.asdf"
export ASDF_DATA_DIR="/home/vscode/.asdf"
export ASDF_FORCE_PREPEND=yes
export MIX_HOME="/home/vscode/.mix"
export HEX_HOME="/home/vscode/.hex"
. "$ASDF_DIR/asdf.sh"

cd /workspace

# Also handles .tool-versions changes made since the image was built.
bash /workspace/.devcontainer/install-tools.sh

mix local.hex --force
mix local.rebar --force
mix deps.get

for demo in demo_berlin_districts demo_gsd_tracker; do
  (
    cd "/workspace/apps/$demo"
    npm ci
    npm ci --prefix assets
  )
done

# Browser libraries are shared; install them once from one locked Playwright
# package. sudo resets PATH on GitHub runners, so retain asdf's npx shim here.
(
  cd /workspace/apps/demo_berlin_districts
  sudo env "PATH=$PATH" npx --no-install playwright install-deps chromium
)

for demo in demo_berlin_districts demo_gsd_tracker; do
  (
    cd "/workspace/apps/$demo"
    # Use each suite's locked Playwright version, not a separate Node feature.
    npx --no-install playwright install chromium
    mix tailwind.install --if-missing
    mix esbuild.install --if-missing
    mix assets.build
  )
done

cd /workspace/apps/demo_gsd_tracker
MIX_ENV=dev mix ecto.create
MIX_ENV=dev mix ecto.migrate
# dev.exs selects gsd_tracker_dev independently of the generic PGDATABASE.
land_cover_present="$(psql -d gsd_tracker_dev -XAt -v ON_ERROR_STOP=1 -c 'SELECT EXISTS (SELECT 1 FROM land_covers)')"
if [[ "$land_cover_present" == "f" ]]; then
  # Populate a new database without duplicating/replacing existing geodata.
  MIX_ENV=dev mix gsd_tracker.fetch_land_cover
fi
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
