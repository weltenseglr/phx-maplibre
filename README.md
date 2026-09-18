# phx-maplibre

**MapLibre maps for Phoenix LiveView that speak PubSub.**

Render a map as a function component. Listen for its whitelisted interactions
from any BEAM process. Drive it from any other process. No `handle_event/3`
required for map traffic, and no LiveComponent holding your map hostage.

`phx_maplibre` keeps the map in the browser and uses per-map PubSub topics as
the bridge: browser events become `%PhxMaplibre.Event{}` structs; commands such
as `set_features/3`, `fly_to/3`, and `fit_bounds/3` travel back the other way.
Your LiveView renders the map, but it does not have to own its data source.

## See it move

- [GSD Tracker](https://gsd-tracker.weltenseglr.de) tracks 24,000 simulated
  Berlin pigeons—obviously government surveillance drones—in real time.
- [Berlin districts](https://phx-maplibre.demo.weltenseglr.de) shows clustered
  POIs, spiderfying, hover, geolocation, theming, and an opt-in shared editor.

Both are real Phoenix apps in this repository, not screenshots with a sales
pitch glued on top.

## Use it

Add the dependency, register `createMapHook(maplibregl)` as
`PhxMaplibreHook` on your `LiveSocket`, render
`PhxMaplibre.Components.map/1`, and call `attach_map/3` in `mount/3`.

```elixir
{:phx_maplibre, "~> 0.2"}
```

Then publish data or issue map commands from wherever they make sense in your
application. The [library README](apps/phx_maplibre/README.md) has copy-ready
installation code, the full API, MapLibre 5/6 compatibility notes, and the
browser-readiness contract.

## Inside this repository

| App | What it proves |
| --- | --- |
| [`apps/phx_maplibre`](apps/phx_maplibre) | The Hex package: a small function-component and PubSub integration layer. |
| [`apps/demo_gsd_tracker`](apps/demo_gsd_tracker) | A GenServer simulation, Ash 3, and PostGIS drive a live map without a map-specific `handle_event/3`. |
| [`apps/demo_berlin_districts`](apps/demo_berlin_districts) | The interaction-heavy demo: clustering, spiderfying, hover, and collaborative drawing. |

## Develop

The devcontainer is the shortest path. It brings PostgreSQL + PostGIS, OSM/GDAL
tools, the project-pinned Erlang/Elixir/Node versions from `.tool-versions`,
dependencies, assets, Playwright Chromium, and seeded GSD databases.

```bash
devcontainer up --workspace-folder .
devcontainer exec mix phx.server
```

That starts Berlin districts on `http://localhost:4001` and GSD Tracker on
`http://localhost:4002`—without an asdf activation or a Hex prompt.

Docker and Podman can run side by side. Set both ports when creating the second
container, then use Podman explicitly with the devcontainer CLI:

```bash
DEMO_PORT=4201 GSD_PORT=4202 \
  DEVCONTAINER_USERNS_MODE=keep-id npx --yes @devcontainers/cli up --docker-path podman --workspace-folder .
```

Changing the image configuration requires a rebuild. The full land-cover
dataset is deliberately absent from Git; setup seeds the small Berlin fixture.

### Native asdf

Native development uses the same `.tool-versions` file. Install the versions,
then fetch the application dependencies and locked browser binaries once:

```bash
asdf install
mix local.hex --force
mix local.rebar --force
mix deps.get
for app in apps/demo_berlin_districts apps/demo_gsd_tracker; do
  npm ci --prefix "$app"
  npm ci --prefix "$app/assets"
  (cd "$app" && npx --no-install playwright install chromium)
done
```

Native verification also needs PostgreSQL with PostGIS available through the
normal application configuration. The devcontainer supplies it for you.

### Verify before committing

Enable the hook once:

```bash
git config core.hooksPath .githooks
```

It runs formatting, all 208 ExUnit tests, 104 JavaScript tests, asset builds,
and both Playwright suites. On the host it uses the ready Docker app service,
then the ready Podman app service, then local asdf tools. A failure blocks the
commit. CI also builds and verifies the full Podman devcontainer; the native
jobs retain package, documentation, and MapLibre compatibility coverage.

```bash
# Docker devcontainer
npx --yes @devcontainers/cli exec --workspace-folder . bash /workspace/scripts/verify

# Podman devcontainer
DEVCONTAINER_USERNS_MODE=keep-id npx --yes @devcontainers/cli exec --docker-path podman --workspace-folder . bash /workspace/scripts/verify

# Native asdf
bash scripts/verify
```

## Documentation

The [library README](apps/phx_maplibre/README.md) is the API reference and the
HexDocs front page. Build it locally with:

```bash
cd apps/phx_maplibre && mix docs
```

## License

EUPL-1.2, unless a file says otherwise. Commercial use is explicitly welcome;
see [LICENSE](LICENSE).
