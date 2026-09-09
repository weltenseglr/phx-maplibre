defmodule DemoWeb.MapLiveTest do
  use DemoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # Map ids are generated per session (see DemoWeb.MapLive), so tests match on
  # the id prefix and read the concrete id out of the rendered markup.
  defp map_id(html, prefix) do
    [_match, id] = Regex.run(~r/id="(#{prefix}-[a-f0-9]+)"/, html)
    id
  end

  defp map_config(html, prefix) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([id^="#{prefix}-"]))
    |> LazyHTML.attribute("data-config")
    |> List.first()
    |> Jason.decode!()
  end

  test "the map id is stable across reloads within one browser session", %{conn: conn} do
    # Same conn (same cookie session) → same viewer id → same map id.
    conn = get(conn, ~p"/map")
    {:ok, _view, first_html} = live(conn)
    {:ok, _view, second_html} = live(conn)

    assert map_id(first_html, "map-districts") == map_id(second_html, "map-districts")

    # A different browser session gets a different id.
    {:ok, _view, other_html} = live(get(build_conn(), ~p"/map"))
    refute map_id(first_html, "map-districts") == map_id(other_html, "map-districts")
  end

  test "mounts the landing page with three map cards", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/map")

    assert html =~ "Three independent map instances"
    assert has_element?(view, ~s([id^="map-geolocation-"]))
    assert has_element?(view, ~s([id^="map-pois-"]))
    assert has_element?(view, ~s([id^="map-districts-"]))
  end

  test "all three maps render the library hook and are update-ignored", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/map")

    assert html =~ ~s(phx-hook="PhxMaplibreHook")
    assert html =~ ~s(phx-update="ignore")

    for prefix <- ~w(map-geolocation map-pois map-districts) do
      assert map_config(html, prefix)["center"] == %{"lat" => 52.52, "lng" => 13.405}
    end
  end

  test "geolocation map opts into the geolocate control", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/map")

    assert map_config(html, "map-geolocation")["geolocation"] == true
    assert map_config(html, "map-pois")["geolocation"] == false
    assert map_config(html, "map-districts")["geolocation"] == false
  end

  test "clustering is only enabled on the POI map", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/map")

    assert map_config(html, "map-pois")["cluster"] == true
    assert map_config(html, "map-geolocation")["cluster"] == false
    assert map_config(html, "map-districts")["cluster"] == false
  end

  test "the districts map whitelists hover events for the harness", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/map")

    events = map_config(html, "map-districts")["events"]

    assert "feature_hovered" in events
    assert "feature_unhovered" in events
    assert "ready" in events

    refute "feature_hovered" in map_config(html, "map-pois")["events"]
  end

  test "the hover harness elements are rendered", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/map")

    assert has_element?(view, "#district-hover-events")
    assert has_element?(view, "#district-hover-event-count")
    assert html =~ ~s(<pre id="district-hover-events" class="hidden">[]</pre>)
  end

  test "district hover events are appended to the harness", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/map")

    districts_map_id = map_id(render(view), "map-districts")

    render_hook(view, "maplibre:event", %{
      "id" => districts_map_id,
      "event" => "feature_hovered",
      "payload" => %{"id" => "district_1", "kind" => "area", "title" => "Mitte"}
    })

    render_hook(view, "maplibre:event", %{
      "id" => districts_map_id,
      "event" => "feature_unhovered",
      "payload" => %{"id" => "district_1", "kind" => "area", "title" => "Mitte"}
    })

    html = render(view)

    assert html =~ "feature_hovered"
    assert html =~ "feature_unhovered"
    assert html =~ ~s(<div id="district-hover-event-count" class="hidden">2</div>)
  end

  test "POI map shows point count", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/map")

    assert html =~ "points of interest"
  end

  test "has link to full explore page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/map")

    assert has_element?(view, "a[href='/explore']")
  end
end
