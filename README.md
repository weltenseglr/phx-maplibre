# phx-maplibre

A [MapLibre GL JS](https://maplibre.org/) integration for Phoenix LiveView.

## Live demos

* **[gsd-tracker.weltenseglr.de](https://gsd-tracker.weltenseglr.de)** — 24,000
  simulated pigeons a.k.a. "Government Surveillance Drone" over Berlin, live.
* **[phx-maplibre.demo.weltenseglr.de](https://phx-maplibre.demo.weltenseglr.de)** —
  Berlin districts and POIs: clustering, hover, geolocation, theming.

## Apps

| App | Description |
|---|---|
| [`apps/phx_maplibre`](apps/phx_maplibre) | The library, packaged for Hex (not published yet). Map events go out on per-map PubSub topics; any BEAM process can drive any map by broadcasting commands. Its [README](apps/phx_maplibre/README.md) has the installation steps and the full API. |
| [`apps/demo_gsd_tracker`](apps/demo_gsd_tracker) | Live tracking of simulated "Government Surveillance Drone" a.k.a. pigeons over Berlin, on Ash 3 + PostGIS with a GenServer simulation, rendered through the library without a single `handle_event` clause. Deployed at [gsd-tracker.weltenseglr.de](https://gsd-tracker.weltenseglr.de). |
| [`apps/demo_berlin_districts`](apps/demo_berlin_districts) | Berlin districts and POIs: clustering, the hover contract, geolocation, theming. Deployed at [phx-maplibre.demo.weltenseglr.de](https://phx-maplibre.demo.weltenseglr.de). |

## Usage

Add `{:phx_maplibre, "~> 0.1"}` to your Phoenix application's dependencies,
register `createMapHook(maplibregl)` as `PhxMaplibreHook` on its `LiveSocket`,
then render `PhxMaplibre.Components.map/1` from a LiveView that uses
`PhxMaplibre.LiveView` and calls `attach_map/3` in `mount/3`. Commands such as
`PhxMaplibre.set_features/3` and `PhxMaplibre.fly_to/3` can then be sent from
any BEAM process. The [library README](apps/phx_maplibre/README.md) has the
copy-ready setup and API reference.

## Development

The easiest way of getting started is to use the devcontainer setup, which ships with PostgreSQL+PostGIS and the OSM/GDAL tools (`osmium`, `ogr2ogr`, and `pg_dump`) used to generate the GSD Tracker's land-cover dataset. Geodata is intentionally not shipped in Git; bootstrap the GSD demo fixture as described in its README. From there it's the usual loop, from the umbrella root:

Enable the repository's full pre-commit verification hook once per checkout:

```bash
git config core.hooksPath .githooks
```

It runs formatting, ExUnit, JavaScript unit tests, asset builds, and both
Playwright suites through the devcontainer. To run the same check without
creating a commit:

```bash
npx --yes @devcontainers/cli exec --workspace-folder . bash /workspace/scripts/verify
```

```sh
mix deps.get
mix compile
MIX_ENV=test mix test        # the container exports MIX_ENV=dev — always be explicit
mix phx.server               # boots both endpoints (:4001 and :4002)
```

For one demo on its own, `cd` into its app directory first:

```sh
cd apps/demo_berlin_districts && mix phx.server   # :4001
cd apps/demo_gsd_tracker && mix phx.server        # :4002
```

## License

EUPL-1.2 for the whole repository unless a file declares its own license —
with an explicit clarification that commercial use is permitted and
encouraged free of charge. See [LICENSE](LICENSE).

## Documentation

[`apps/phx_maplibre/README.md`](apps/phx_maplibre/README.md) is the library's
reference and doubles as the HexDocs main page;
`cd apps/phx_maplibre && mix docs` builds it locally.
