# GSD Tracker: a pigeon-shaped learning lab

GSD Tracker is a deliberately playful live map of simulated “Government
Surveillance Drone” pigeons moving around Berlin. The joke is an homage to
[Birds Aren't Real](https://pigeonsarentreal.co.uk), but the app has a serious
purpose: it is a place to learn the Erlang/Elixir ecosystem by building a
recognizable, stateful, real-time application from end to end.

From a human perspective, this is an experiment in getting comfortable with
the tools rather than a claim to model real birds. It lets us explore how
Phoenix LiveView feels when a map, a database, background processes, and many
connected browsers are all changing together. The silly subject keeps the
work approachable while the system remains substantial enough to expose real
engineering questions.

## What it explores

- **Erlang/OTP:** supervised processes, message passing, fault isolation, and
  long-running simulation work.
- **Phoenix and LiveView:** server-rendered, real-time UI updates without
  turning every interaction into a bespoke browser-to-server event handler.
- **Ash, Ecto, and Postgres/PostGIS:** resource modelling, persistence, and
  geographic data.
- **PubSub and `phx_maplibre`:** map commands and map interactions travel as
  messages, so any BEAM process can drive the interface.
- **Performance:** a flock of thousands of units is useful for learning where
  scheduling, data volume, rendering, database work, and browser updates begin
  to matter.

The simulation intentionally fluctuates rather than following a fixed quota:
most pigeons are active during the day, some take short charging or maintenance
breaks, and a small probabilistic fraction remains active at night. Couples are
linked on the map so selecting one highlights its partner.

## Running it

From the umbrella root, start the demo in the devcontainer:

```bash
cd apps/demo_gsd_tracker
mix ecto.create
mix ecto.migrate
mix gsd_tracker.fetch_land_cover
mix phx.server
```

Visit [http://localhost:4002](http://localhost:4002). The in-app **About this
demo** page contains the same explanation for visitors. The fetch task loads
the small Berlin fixture, which is suitable for ordinary local development.

## Land and water data

No generated land-cover dataset is shipped in this Git repository. Bootstrap
the GSD demo before running it: use `mix gsd_tracker.fetch_land_cover` for the
small tracked Berlin fixture during ordinary local development, or generate the
full OSM-derived `priv/data/land_covers.dump` as described below. The demo
Compose stack mounts the generated dump
read-only into an importer, which
restores it after migrations and records the dump checksum on the `land_covers`
table. Generate the dump before starting the Compose stack; to replace it,
regenerate the dataset, then run
`docker compose -f compose.demo.yml up -d`.

To build and load the full dataset instead, run this from
`apps/demo_gsd_tracker` in the devcontainer:

```bash
mix ecto.create
mix ecto.migrate
bash priv/scripts/extract_land_cover.sh
```

The devcontainer already includes the required `osmium`, GDAL/`ogr2ogr`, and
PostgreSQL client tools. The demo Compose stack builds the same
OSM/GDAL toolchain into its `land-cover-import` image, so imports and future
dataset rebuilds do not depend on host-installed binaries. The script downloads
the official OpenStreetMap planet PBF to a temporary directory outside the
repository, filters the required polygons, loads them into the database, and
writes `priv/data/land_covers.dump`. Set
`LAND_COVER_CACHE_DIR` to retain a reusable download cache. The source planet
is about 88 GB, so run it only deliberately on a machine with sufficient disk
space and time.

When synchronizing a checkout, use `rsync -a --filter='merge .rsync-filter'`
so the generated dump and architecture-specific build output stay local.

## Readiness and browser tests

The connection badge exposes `data-connection="offline"` on the initial HTML
and `"live"` when its LiveView hook mounts or reconnects. The hook keeps the
badge consistent across server patches and marks it offline on disconnect.
`#gsd-tracker[data-simulation-revision]` starts at zero and increments when a
simulation broadcast is handled. Tests can wait for a revision change instead
of sleeping for an assumed simulation interval.

Map readiness is separate: `data-map-hook-ready`, `data-map-style-ready`,
`data-map-loaded` (initial load milestone), and `data-map-points-present` (nonempty
point collection). The library's exported `getMapHandle(element)` returns a
frozen handle with `map` and the current `pointsData` getter, or `null` before
mounting and after destruction. The demo exposes this accessor as
`window.phxMaplibre.getMapHandle` for its browser tests. See the [library examples](../phx_maplibre/README.md#browser-readiness-and-playwright)
for polling rendered pins and selecting one through a real mouse click.

Run from this app directory:

```bash
npx playwright test --reporter=line --workers=1
npx playwright test --reporter=line --workers=4
```

For a separate server port, set `GSD_PORT` and `DEMO_PORT` together:

```bash
GSD_PORT=4102 DEMO_PORT=4101 npx playwright test --reporter=line
```

The pin test waits for initial position data because a fresh server builds its
fleet asynchronously. It then zooms to a real position and waits for a rendered
pin; receiving GeoJSON alone does not imply rendering has finished.

Headless test launches clear the inherited `DISPLAY` value, since a forwarded
IDE display can be inaccessible inside the devcontainer and prevent ANGLE from
initializing WebGL. Headed/debug launches preserve the display. Map setup
failures report `data-map-lifecycle`, `data-map-mount-count`, and `data-map-error`
in readiness assertions instead of timing out on an unexplained false flag.

For interactive inspection, run with a
virtual display on Linux:

```bash
xvfb-run -a npx playwright test --headed --reporter=line
```
