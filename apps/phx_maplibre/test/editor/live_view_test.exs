defmodule PhxMaplibre.Editor.LiveViewTest do
  use ExUnit.Case, async: true
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias PhxMaplibre.Editor.{Document, Runtime}
  @endpoint PhxMaplibre.TestSupport.Endpoint

  defp conn, do: Plug.Test.init_test_session(build_conn(), %{})
  defp socket(view), do: :sys.get_state(view.pid).socket

  test "an ordinary map has no editor registration or editor hook" do
    {:ok, view, html} = live_isolated(conn(), PhxMaplibre.TestSupport.TestLive)
    refute Map.has_key?(socket(view).assigns, :__phx_maplibre_editors__)
    refute html =~ "PhxMaplibreEditorHook"
    refute html =~ "data-editor-config"
  end

  test "editor registrations bind distinct actors and isolate document mutations" do
    runtime = start_supervised!({Runtime, pubsub: PhxMaplibre.TestPubSub})

    {:ok, view, _html} =
      live_isolated(conn(), PhxMaplibre.TestSupport.EditorLive, session: %{"runtime" => runtime})

    registrations = socket(view).assigns.__phx_maplibre_editors__
    one = registrations["editor-one"]
    two = registrations["editor-two"]
    assert one.actor != two.actor
    assert one.user["id"] == two.user["id"]
    assert one.document_id == "first"
    assert two.document_id == "second"

    render_hook(view, "maplibre:editor", %{
      "id" => "editor-one",
      "event" => "mutate",
      "payload" => %{
        "action" => "create",
        "mode" => "polygon",
        "feature" => %{
          "id" => "polygon",
          "type" => "Feature",
          "properties" => %{"custom" => "kept"},
          "geometry" => %{
            "type" => "Polygon",
            "coordinates" => [[[0, 0], [4, 0], [0, 4], [0, 0]]]
          }
        }
      }
    })

    {:ok, first} = Runtime.resolve(runtime, "first")
    {:ok, second} = Runtime.resolve(runtime, "second")

    assert [%{"id" => "polygon", "properties" => %{"custom" => "kept"}}] =
             Document.snapshot(first).features

    assert Document.snapshot(second).features == []

    render_hook(view, "maplibre:editor", %{
      "id" => "unregistered",
      "event" => "settings",
      "payload" => %{"update_interval_ms" => 25}
    })

    assert Document.snapshot(first).settings.update_interval_ms == 500
    assert render(view)
  end

  test "two editor instances in the same browser session have distinct actors" do
    runtime = start_supervised!({Runtime, pubsub: PhxMaplibre.TestPubSub})

    {:ok, first, _} =
      live_isolated(conn(), PhxMaplibre.TestSupport.EditorLive, session: %{"runtime" => runtime})

    {:ok, second, _} =
      live_isolated(conn(), PhxMaplibre.TestSupport.EditorLive, session: %{"runtime" => runtime})

    actor = fn view -> socket(view).assigns.__phx_maplibre_editors__["editor-one"].actor end
    assert actor.(first) != actor.(second)
  end

  test "two editors sharing a document receive one scoped broadcast each" do
    runtime = start_supervised!({Runtime, pubsub: PhxMaplibre.TestPubSub})

    {:ok, view, _} =
      live_isolated(conn(), PhxMaplibre.TestSupport.EditorLive,
        session: %{"runtime" => runtime, "second_document" => "first"}
      )

    render_hook(view, "maplibre:editor", %{
      "id" => "editor-one",
      "event" => "settings",
      "payload" => %{"update_interval_ms" => 25}
    })

    assert_push_event(view, "maplibre:editor:editor-one:snapshot", %{
      settings: %{update_interval_ms: 25}
    })

    assert_push_event(view, "maplibre:editor:editor-two:snapshot", %{
      settings: %{update_interval_ms: 25}
    })

    {:ok, doc} = Runtime.resolve(runtime, "first")
    assert length(Document.snapshot(doc).presence.entries) == 2
  end

  test "component scopes its hook and serializes explicit configuration" do
    html =
      render_component(&PhxMaplibre.Components.editor/1,
        id: "editor",
        map_id: "map",
        config: %{modes: ["point", "select"], fields: [], control: "measure"}
      )

    assert html =~ ~s(phx-hook="PhxMaplibreEditorHook")
    assert html =~ ~s(data-map-id="map")
    assert html =~ "measure"
    refute html =~ "selected-name"
    refute html =~ "selected-color"
  end
end
