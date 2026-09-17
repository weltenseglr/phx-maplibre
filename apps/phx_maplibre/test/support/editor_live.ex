defmodule PhxMaplibre.TestSupport.EditorLive do
  @moduledoc false
  use Phoenix.LiveView
  use PhxMaplibre.LiveView

  @impl true
  def mount(_params, %{"runtime" => runtime} = session, socket) do
    socket =
      socket
      |> PhxMaplibre.LiveView.attach_map("editor-map", pubsub: PhxMaplibre.TestPubSub)
      |> PhxMaplibre.LiveView.attach_editor("editor-one",
        runtime: runtime,
        document_id: "first",
        modes: ["polygon", "select"],
        user: %{id: "same-user", name: "Visitor", color: "#f97316"}
      )
      |> PhxMaplibre.LiveView.attach_editor("editor-two",
        runtime: runtime,
        document_id: session["second_document"] || "second",
        modes: ["point", "select"],
        user: %{id: "same-user", name: "Visitor", color: "#f97316"}
      )

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhxMaplibre.Components.map id="editor-map" />
    <PhxMaplibre.Components.editor
      id="editor-one"
      map_id="editor-map"
      config={%{modes: ["polygon", "select"]}}
    />
    <PhxMaplibre.Components.editor
      id="editor-two"
      map_id="editor-map"
      config={%{modes: ["point", "select"]}}
    />
    """
  end
end
