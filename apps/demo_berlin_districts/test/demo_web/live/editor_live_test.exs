defmodule DemoWeb.EditorLiveTest do
  use DemoWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias PhxMaplibre.Editor.{Document, Runtime}

  defp event(view, event, payload) do
    render_hook(view, "maplibre:editor", %{id: "shared-editor", event: event, payload: payload})
  end

  setup do
    {:ok, doc} = Runtime.resolve(Demo.EditorRuntime, "shared-drawings")
    Document.join(doc, "test-cleanup", %{})

    for feature <- Document.snapshot(doc).features do
      Document.mutate(doc, "test-cleanup", %{"action" => "delete", "id" => feature["id"]})
    end

    Document.settings(doc, "test-cleanup", %{"update_interval_ms" => 500})
    Document.leave(doc, "test-cleanup")
    %{doc: doc}
  end

  test "demo configures the library editor and shares features", %{conn: conn, doc: doc} do
    {:ok, first, html} = live(conn, ~p"/editor")
    {:ok, second, _} = live(build_conn(), ~p"/editor")
    assert html =~ "Shared drawings"
    assert has_element?(first, "#shared-editor[phx-hook=PhxMaplibreEditorHook]")
    id = "test-" <> Integer.to_string(System.unique_integer([:positive]))

    event(first, "mutate", %{
      action: "create",
      mode: "polygon",
      vertex_ids: ["a", "b", "c"],
      feature: %{
        type: "Feature",
        id: id,
        properties: %{name: "Garden"},
        geometry: %{type: "Polygon", coordinates: [[[13, 52], [14, 52], [14, 53], [13, 52]]]}
      }
    })

    assert_push_event(second, "maplibre:editor:shared-editor:snapshot", %{
      features: [%{"id" => ^id}]
    })

    event(second, "mutate", %{action: "properties", id: id, properties: %{name: "Shared garden"}})

    assert_push_event(first, "maplibre:editor:shared-editor:snapshot", %{
      features: [%{"properties" => %{"name" => "Shared garden"}}]
    })

    event(first, "mutate", %{action: "delete", id: id})
    assert_push_event(second, "maplibre:editor:shared-editor:snapshot", %{features: []})
    assert Document.snapshot(doc).features == []
  end

  test "same-session tabs have separate actors and shared settings", %{conn: conn, doc: doc} do
    conn = init_test_session(conn, %{"viewer_id" => "abcdef0123456789abcdef0123456789"})
    {:ok, first, _} = live(conn, ~p"/editor")
    {:ok, second, _} = live(conn, ~p"/editor")
    actors = Document.snapshot(doc).presence.entries |> Enum.map(& &1.actor_id)
    assert length(Enum.uniq(actors)) == 2
    event(first, "settings", %{update_interval_ms: 25})

    assert_push_event(second, "maplibre:editor:shared-editor:snapshot", %{
      settings: %{update_interval_ms: 25}
    })

    event(second, "settings", %{update_interval_ms: 0})
    assert Document.snapshot(doc).settings.update_interval_ms == 25
  end

  test "invalid creation leaves authoritative state intact", %{conn: conn, doc: doc} do
    {:ok, view, _} = live(conn, ~p"/editor")
    before = Document.snapshot(doc)
    event(view, "mutate", %{action: "create", mode: "polygon", feature: %{geometry: nil}})
    assert Document.snapshot(doc).features == before.features
    assert Document.snapshot(doc).revision == before.revision
  end
end
