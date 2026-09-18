# Berlin MapLibre demo

Run `mix phx.server` in this directory and open http://localhost:4001.

- `/map`: geolocation, clustered POIs, and district hover examples.
- `/explore`: browse nearby venues.
- `/editor`: a shared feature editor using phx-maplibre's optional Terra Draw integration.

Use the upstream map toolbar to draw, select, edit, measure, delete, and undo.
The configured modes include points, markers, lines, polygons, rectangles,
circles, freehand drawings, sensors, sectors, and text. Other visitors see
unfinished drawings and cursors. Drafts belong to their creator; completed
features can be edited concurrently. The sidebar configures application name
and color fields, a shared update interval (25–2000 ms), and a local cursor
interpolation preference. Reduced-motion settings disable interpolation.

`EditorLive` renders `PhxMaplibre.Components.editor` beside an ordinary map,
and explicitly calls `PhxMaplibre.LiveView.attach_editor/3`.
`Demo.Application` explicitly starts `PhxMaplibre.Editor.Runtime` with
`Demo.PubSub`. The demo imports `phx_maplibre/editor` and upstream control CSS;
all drawing, presence, synchronization, and history logic belongs to the library.
The default runtime is ephemeral: restarting it clears drawings and shared settings.
Application storage and ownership adapters can provide durable, distributed state.
See [the library setup and adapter documentation](../phx_maplibre/README.md)
and [Ash/PostGIS example](../phx_maplibre/examples/ash_postgis_editor.md).

Install assets with `mix assets.setup`, then build with `mix assets.build`.
Run server tests with `MIX_ENV=test mix test`, library JavaScript checks with
`node --test ../phx_maplibre/test/js/*.test.mjs`, and browser checks with
`npx playwright test --workers=1` against the running demo.
