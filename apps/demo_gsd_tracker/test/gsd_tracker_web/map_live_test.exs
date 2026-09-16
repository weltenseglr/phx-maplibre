defmodule GsdTrackerWeb.MapLiveTest do
  use GsdTracker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhxMaplibre.Command
  alias PhxMaplibre.Event

  @endpoint GsdTrackerWeb.Endpoint
  @map_id_prefix "map-tracker"

  @berlin_bounds %{west: 13.0, south: 52.0, east: 14.0, north: 53.0}
  @antimeridian_bounds %{west: 170.0, south: -10.0, east: -170.0, north: 10.0}

  describe "rendering" do
    test "GET / renders the map container and the stats sidebar" do
      conn = get(build_conn(), "/")
      html = html_response(conn, 200)

      assert html =~ ~s(id="#{@map_id_prefix}-)
      assert html =~ ~s(id="stats-sidebar")
      assert html =~ "Total Pigeons"
    end

    test "GET /about explains the demo's learning purpose" do
      conn = get(build_conn(), "/about")
      html = html_response(conn, 200)

      assert html =~ "A pigeon-shaped learning lab"
      assert html =~ "Erlang/OTP"
      assert html =~ "Performance"
    end

    test "renders the connection badge as offline until LiveView connects" do
      conn = get(build_conn(), "/")
      html = html_response(conn, 200)

      assert html =~ ~s(id="gsd-connection-status")
      assert html =~ "is-offline"
      assert html =~ "Offline"
      assert html =~ ~s(phx-hook="ConnectionStatus")
      assert html =~ ~s(data-connection="offline")
    end

    test "renders simulation stats broadcast on the gsd_updates topic" do
      {:ok, view, _html} = live(build_conn(), "/")

      send(
        view.pid,
        {:update, %{positions: [], stats: stats(total: 100, couples: 85, flocks: 10)}}
      )

      html = render(view)

      assert html =~ ~s(data-simulation-revision="1")
      assert html =~ "Total Pigeons"
      assert html =~ "100"
      assert html =~ "Couples"
      assert html =~ "85"
      assert html =~ "Flocks"
      assert html =~ "10"
    end
  end

  describe "map commands" do
    test "pushes only the features inside the viewport" do
      {:ok, view, _html} = live(build_conn(), "/")
      map_id = subscribe_to_commands(view)

      send(view.pid, ready_event(map_id, @berlin_bounds))
      _html = render(view)

      # The seed push that follows :ready (no persisted stats in the sandbox).
      assert_receive %Command{map_id: ^map_id, command: :set_features}

      positions = [
        position("11111111-1111-1111-1111-111111111111", 52.5, 13.4,
          status: :surveillance,
          speed_kmh: 12.34,
          movement_vector: %{lat: 1.0, lng: 1.0}
        ),
        position("22222222-2222-2222-2222-222222222222", 60.0, 20.0, status: :charging)
      ]

      send(view.pid, {:update, %{positions: positions, stats: stats(total: 2)}})
      _html = render(view)

      assert_receive %Command{
        map_id: ^map_id,
        command: :set_features,
        params: %{geojson: %{type: "FeatureCollection", features: features}}
      }

      assert [feature] = features
      assert feature.id == "11111111-1111-1111-1111-111111111111"
      assert feature.geometry == %{type: "Point", coordinates: [13.4, 52.5]}
      assert feature.properties.kind == "gsd"
      assert feature.properties.status == "surveillance"
      assert feature.properties.title == "GSD 11111111"
      assert feature.properties.speed_kmh == 12.3
      assert feature.properties.bearing == 45.0
    end

    test "the viewport filter wraps across the antimeridian" do
      {:ok, view, _html} = live(build_conn(), "/")
      map_id = subscribe_to_commands(view)

      send(view.pid, ready_event(map_id, @antimeridian_bounds))
      _html = render(view)
      assert_receive %Command{command: :set_features}

      positions = [
        position("33333333-3333-3333-3333-333333333333", 0.0, 175.0),
        position("44444444-4444-4444-4444-444444444444", 0.0, -175.0),
        position("55555555-5555-5555-5555-555555555555", 0.0, 0.0),
        position("66666666-6666-6666-6666-666666666666", 80.0, 175.0)
      ]

      send(view.pid, {:update, %{positions: positions, stats: stats(total: 4)}})
      _html = render(view)

      assert_receive %Command{command: :set_features, params: %{geojson: %{features: features}}}

      assert Enum.map(features, & &1.id) == [
               "33333333-3333-3333-3333-333333333333",
               "44444444-4444-4444-4444-444444444444"
             ]
    end

    test "does not push features before the map is ready" do
      {:ok, view, _html} = live(build_conn(), "/")
      _map_id = subscribe_to_commands(view)

      send(view.pid, {:update, %{positions: [position(), position()], stats: stats(total: 2)}})
      _html = render(view)

      refute_receive %Command{command: :set_features}, 100
    end
  end

  describe "selection" do
    test "renders the detail panel for the selected feature" do
      commissioning_date =
        DateTime.utc_now() |> DateTime.add(-172_800, :second) |> DateTime.truncate(:second)

      gsd =
        GsdTracker.GSD
        |> Ash.Changeset.for_create(:create, %{
          commissioning_date: commissioning_date,
          status: :simulating
        })
        |> Ash.create!(domain: GsdTracker.Ash)

      {:ok, view, _html} = live(build_conn(), "/")

      send(view.pid, feature_selected_event(map_id(view), gsd.id))
      html = render(view)

      assert html =~ ~s(id="gsd-detail")
      assert html =~ "GSD " <> String.slice(gsd.id, 0, 8)
      assert html =~ "Total distance:"
      assert html =~ "0.0 m"
      assert html =~ "Service time:"
      assert html =~ "2d 0h"
      assert html =~ "Speed"
      assert html =~ "Heading"

      # A tick refreshes the live fields of the open detail panel.
      position =
        position(gsd.id, 52.5, 13.4,
          status: :target_tracking,
          speed_kmh: 42.5,
          movement_vector: %{lat: 1.0, lng: 0.0}
        )

      send(view.pid, {:update, %{positions: [position], stats: stats(total: 1)}})
      html = render(view)

      assert html =~ "42.5 km/h"
      assert html =~ "0.0° N"
      assert html =~ "Target tracking"
      assert html =~ "s ago"
    end

    test "clears the detail panel when the feature is deselected" do
      commissioning_date =
        DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.truncate(:second)

      gsd =
        GsdTracker.GSD
        |> Ash.Changeset.for_create(:create, %{
          commissioning_date: commissioning_date,
          status: :charging
        })
        |> Ash.create!(domain: GsdTracker.Ash)

      {:ok, view, _html} = live(build_conn(), "/")

      map_id = map_id(view)

      send(view.pid, feature_selected_event(map_id, gsd.id))
      assert render(view) =~ ~s(id="gsd-detail")

      send(view.pid, %Event{
        map_id: map_id,
        event: :feature_deselected,
        payload: %{id: gsd.id, kind: "point"},
        meta: %{}
      })

      refute render(view) =~ ~s(id="gsd-detail")
    end

    test "ignores map events it does not care about" do
      {:ok, view, _html} = live(build_conn(), "/")

      send(view.pid, %Event{
        map_id: map_id(view),
        event: :cluster_selected,
        payload: %{cluster_id: 1, point_count: 3, center: %{lng: 13.4, lat: 52.5}},
        meta: %{}
      })

      assert render(view) =~ ~s(id="stats-sidebar")
    end
  end

  ## Fixtures

  # The map id is generated per session (see GsdTrackerWeb.MapLive), so tests
  # read it back out of the rendered markup and subscribe to that map's topic.
  defp map_id(view) do
    [_match, id] = Regex.run(~r/id="(#{@map_id_prefix}-[a-f0-9]+)"/, render(view))
    id
  end

  defp subscribe_to_commands(view) do
    id = map_id(view)
    :ok = Phoenix.PubSub.subscribe(GsdTracker.PubSub, "phx_maplibre:#{id}:commands")
    id
  end

  defp ready_event(map_id, bounds) do
    %Event{
      map_id: map_id,
      event: :ready,
      payload: %{bounds: bounds, center: %{lng: 13.405, lat: 52.52}, zoom: 11},
      meta: %{}
    }
  end

  defp feature_selected_event(map_id, id) do
    %Event{
      map_id: map_id,
      event: :feature_selected,
      payload: %{
        id: id,
        kind: "point",
        title: "GSD",
        lng: 13.4,
        lat: 52.5,
        properties: %{"id" => id}
      },
      meta: %{}
    }
  end

  defp position(
         id \\ "77777777-7777-7777-7777-777777777777",
         lat \\ 52.5,
         lng \\ 13.4,
         opts \\ []
       ) do
    %{
      gsd_id: id,
      lat: lat,
      lng: lng,
      status: Keyword.get(opts, :status, :surveillance),
      flock_id: Keyword.get(opts, :flock_id),
      partner_id: Keyword.get(opts, :partner_id),
      speed_kmh: Keyword.get(opts, :speed_kmh),
      movement_vector: Keyword.get(opts, :movement_vector),
      last_update_at: Keyword.get(opts, :last_update_at, DateTime.utc_now())
    }
  end

  defp stats(opts) do
    %{
      total: Keyword.get(opts, :total, 0),
      couples: Keyword.get(opts, :couples, 0),
      flocks: Keyword.get(opts, :flocks, 0),
      largest_flock: Keyword.get(opts, :largest_flock, 0),
      smallest_flock: Keyword.get(opts, :smallest_flock, 0),
      avg_flock_size: Keyword.get(opts, :avg_flock_size, 0),
      by_state: %{
        ground: %{maintenance: 0, charging: 0, surveillance: 0, simulating: 0},
        flight: %{target_tracking: 0, aerial_surveillance: 0, moving_to_new_target: 0}
      }
    }
  end
end
