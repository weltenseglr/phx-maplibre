defmodule DemoWeb.ExploreLiveTest do
  use DemoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @map_id_prefix "map-explore"

  # The map id is generated per session (see DemoWeb.ExploreLive), so it is read
  # back out of the rendered markup instead of being hard-coded.
  defp map_id(view) do
    [_match, id] = Regex.run(~r/id="(#{@map_id_prefix}-[a-f0-9]+)"/, render(view))
    id
  end

  defp map_event(view, event, payload) do
    render_hook(view, "maplibre:event", %{
      "id" => map_id(view),
      "event" => event,
      "payload" => payload
    })

    # The hook relays through PubSub, so the resulting %PhxMaplibre.Event{} is
    # handled in the next message — force a round trip before asserting.
    render(view)
  end

  defp ready(view), do: map_event(view, "ready", viewport())

  defp viewport do
    %{
      "bounds" => %{"west" => 13.0, "south" => 52.3, "east" => 13.8, "north" => 52.7},
      "center" => %{"lng" => 13.405, "lat" => 52.52},
      "zoom" => 11
    }
  end

  test "mounts the explore page", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/explore")

    assert has_element?(view, ~s([id^="#{@map_id_prefix}-"]))
    assert has_element?(view, "#feature-cards")
    assert html =~ "Venues"
    assert html =~ ~s(phx-hook="PhxMaplibreHook")
  end

  test "ready event populates feature cards", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/explore")

    ready(view)

    assert has_element?(view, "#feature-cards .map-card")
  end

  test "move_end event refreshes feature cards", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/explore")

    ready(view)
    map_event(view, "move_end", viewport())

    assert has_element?(view, "#feature-cards .map-card")
  end

  test "feature selection opens detail panel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/explore")

    ready(view)

    map_event(view, "feature_selected", %{
      "id" => "venue_test",
      "kind" => "point",
      "lng" => 13.405,
      "lat" => 52.52,
      "feature" => %{
        "type" => "Feature",
        "id" => "venue_test",
        "geometry" => %{"type" => "Point", "coordinates" => [13.405, 52.52]},
        "properties" => %{
          "id" => "venue_test",
          "title" => "Test Studio",
          "description" => "Test Area",
          "kind" => "venue",
          "category" => "yoga"
        }
      }
    })

    assert has_element?(view, "#detail-panel")
    assert render(view) =~ "Test Studio"
  end

  test "close_detail closes the panel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/explore")

    ready(view)

    map_event(view, "feature_selected", %{
      "id" => "venue_test",
      "kind" => "point",
      "lng" => 13.4,
      "lat" => 52.5,
      "feature" => %{
        "type" => "Feature",
        "id" => "venue_test",
        "geometry" => %{"type" => "Point", "coordinates" => [13.4, 52.5]},
        "properties" => %{
          "id" => "venue_test",
          "title" => "Test",
          "description" => "Area",
          "category" => "yoga"
        }
      }
    })

    assert has_element?(view, "#detail-panel")

    render_hook(view, "close_detail", %{})
    refute has_element?(view, "#detail-panel")
  end

  test "geolocation error shows fallback", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/explore")

    ready(view)
    map_event(view, "geolocation_error", %{"code" => 1, "message" => "Denied"})

    assert has_element?(view, ".map-geo-fallback")
  end

  test "card selection opens detail", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/explore")

    html = ready(view)
    assert html =~ "map-card"

    [_match, feature_id] = Regex.run(~r/phx-value-id="([^"]+)"/, html)
    render_hook(view, "select_card", %{"id" => feature_id})

    assert has_element?(view, "#detail-panel")
  end
end
