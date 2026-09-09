defmodule GsdTrackerWeb.Components.StatsSidebarTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GsdTrackerWeb.Components.StatsSidebar

  @stats %{
    total: 100,
    couples: 85,
    flocks: 10,
    largest_flock: 15,
    smallest_flock: 3,
    avg_flock_size: 8.5,
    by_state: %{
      ground: %{maintenance: 10, charging: 5, surveillance: 20, simulating: 15},
      flight: %{target_tracking: 25, aerial_surveillance: 15, moving_to_new_target: 10}
    }
  }

  test "renders every aggregate stat" do
    html = render_component(&StatsSidebar.stats_sidebar/1, stats: @stats)

    assert html =~ ~s(id="stats-sidebar")
    assert html =~ "Total Pigeons"
    assert html =~ "100"
    assert html =~ "Couples"
    assert html =~ "85"
    assert html =~ "Flocks"
    assert html =~ "Largest Flock"
    assert html =~ "15"
    assert html =~ "Smallest Flock"
    assert html =~ "Avg Flock Size"
    assert html =~ "8.5"
  end

  test "renders the ground and flight breakdowns" do
    html = render_component(&StatsSidebar.stats_sidebar/1, stats: @stats)

    assert html =~ "Ground States"
    assert html =~ "Maintenance"
    assert html =~ "Charging"
    assert html =~ "Surveillance"
    assert html =~ "Simulating"
    assert html =~ "Flight States"
    assert html =~ "Target Tracking"
    assert html =~ "Aerial Surveillance"
    assert html =~ "Moving To New Target"
  end

  test "survives an integer avg_flock_size" do
    stats = %{@stats | avg_flock_size: 0}

    html = render_component(&StatsSidebar.stats_sidebar/1, stats: stats)

    assert html =~ "Avg Flock Size"
    assert html =~ "0.0"
  end

  test "falls back to zero for missing state counts" do
    stats = %{@stats | by_state: %{ground: %{}, flight: %{}}}

    html = render_component(&StatsSidebar.stats_sidebar/1, stats: stats)

    assert html =~ "Ground States"
    assert html =~ "Flight States"
  end

  test "renders the gsd detail panel" do
    detail = %{
      gsd_id: "11111111-1111-1111-1111-111111111111",
      title: "GSD 11111111",
      status: :target_tracking,
      speed_kmh: 42.5,
      movement_vector: %{lat: 0.0, lng: 1.0},
      bearing: 90.0,
      total_distance_m: 1234.56,
      service_time: "2d 3h",
      last_update_at: DateTime.add(DateTime.utc_now(), -3, :second),
      flock_id: nil,
      partner_id: nil
    }

    html = render_component(&StatsSidebar.gsd_detail/1, detail: detail)

    assert html =~ ~s(id="gsd-detail")
    assert html =~ "GSD 11111111"
    assert html =~ "Target tracking"
    assert html =~ "42.5 km/h"
    assert html =~ "90.0° E"
    assert html =~ "rotate(90.0deg)"
    assert html =~ "Total distance:"
    assert html =~ "1234.6 m"
    assert html =~ "Service time:"
    assert html =~ "2d 3h"
    assert html =~ "3s ago"
  end

  test "renders placeholders when the live fields are unknown" do
    detail = %{
      gsd_id: "11111111-1111-1111-1111-111111111111",
      title: "GSD 11111111",
      status: :charging,
      speed_kmh: nil,
      movement_vector: nil,
      bearing: nil,
      total_distance_m: 0.0,
      service_time: "0d 1h",
      last_update_at: nil,
      flock_id: nil,
      partner_id: nil
    }

    html = render_component(&StatsSidebar.gsd_detail/1, detail: detail)

    assert html =~ "0.0 m"
    assert html =~ "—"
    refute html =~ "km/h"
  end
end
