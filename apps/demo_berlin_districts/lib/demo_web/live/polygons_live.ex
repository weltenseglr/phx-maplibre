defmodule DemoWeb.PolygonsLive do
  use DemoWeb, :live_view
  use PhxMaplibre.LiveView

  @impl true
  def mount(_params, session, socket) do
    viewer = session["viewer_id"] || Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    map_id = "map-polygons-" <> viewer

    config = %{
      modes: PhxMaplibre.Editor.Config.modes(),
      control: "measure",
      control_options: %{open: true, showDeleteConfirmation: false},
      fields: ["name", "color"]
    }

    {:ok,
     socket
     |> assign(
       map_id: map_id,
       editor_config: config,
       center: Demo.Map.default_center(),
       zoom: Demo.Map.default_zoom()
     )
     |> PhxMaplibre.LiveView.attach_map(map_id, pubsub: Demo.PubSub, events: [:ready])
     |> PhxMaplibre.LiveView.attach_editor("shared-editor",
       runtime: Demo.EditorRuntime,
       document_id: "shared-drawings",
       modes: config.modes,
       user: %{
         id: viewer,
         name: "Visitor " <> String.slice(viewer, 0, 4),
         color: "#" <> String.slice(viewer, 0, 6)
       }
     )}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} fluid={true}>
      <div class="polygon-editor">
        <aside class="polygon-sidebar">
          <PhxMaplibre.Components.editor id="shared-editor" map_id={@map_id} config={@editor_config}>
            <h1 class="text-xl font-semibold">Shared drawings</h1>
            <p class="text-sm opacity-70">
              Use the map toolbar to draw and edit. Everyone sees unfinished drawings;
              completed features can be edited concurrently. Drawings reset with this server.
            </p>
          </PhxMaplibre.Components.editor>
        </aside>
        <div class="polygon-map">
          <PhxMaplibre.Components.map
            id={@map_id}
            center={@center}
            zoom={@zoom}
            events={[:ready]}
            cluster={false}
            class="h-full w-full"
          />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
