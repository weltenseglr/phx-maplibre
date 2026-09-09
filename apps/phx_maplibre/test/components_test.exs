defmodule PhxMaplibre.ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  defp render_map(assigns) do
    render_component(&PhxMaplibre.Components.map/1, assigns)
  end

  defp decode_config(html) do
    [_, encoded] = Regex.run(~r/data-config="([^"]*)"/, html)

    encoded
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
    |> Jason.decode!()
  end

  test "renders the container with hook wiring" do
    html = render_map(id: "m1")

    assert html =~ ~s(id="m1")
    assert html =~ ~s(phx-hook="PhxMaplibreHook")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ "phx-maplibre"
  end

  test "serializes defaults into data-config" do
    config = decode_config(render_map(id: "m1"))

    assert config["center"] == %{"lng" => 13.405, "lat" => 52.52}
    assert config["zoom"] == 11
    assert config["cluster"] == true
    assert config["navigation"] == true
    assert config["geolocation"] == false
    assert config["flyOnGeolocate"] == true
    assert config["moveEndThrottleMs"] == 1000
    assert config["lightStyle"] =~ "positron"
    assert config["darkStyle"] =~ "dark-matter"
  end

  test "animation is on by default and serializes as animateMinZoom" do
    assert decode_config(render_map(id: "m1"))["animateMinZoom"] == 12
    assert decode_config(render_map(id: "m1", animate_min_zoom: 10.5))["animateMinZoom"] == 10.5
  end

  test "animate_min_zoom accepts false or nil to opt out, serializing false" do
    assert decode_config(render_map(id: "m1", animate_min_zoom: false))["animateMinZoom"] == false
    assert decode_config(render_map(id: "m1", animate_min_zoom: nil))["animateMinZoom"] == false
  end

  test "an invalid animate_min_zoom raises naming the attribute" do
    assert_raise ArgumentError, ~r/animate_min_zoom/, fn ->
      render_map(id: "m1", animate_min_zoom: "twelve")
    end
  end

  test "default events whitelist excludes hover" do
    config = decode_config(render_map(id: "m1"))

    assert "ready" in config["events"]
    assert "move_end" in config["events"]
    assert "feature_selected" in config["events"]
    refute "feature_hovered" in config["events"]
    refute "feature_unhovered" in config["events"]
  end

  test "events are serialized as strings in the given order" do
    config = decode_config(render_map(id: "m1", events: [:ready, :feature_hovered]))
    assert config["events"] == ["ready", "feature_hovered"]
  end

  test "custom attrs override defaults" do
    html =
      render_map(
        id: "m2",
        center: %{lng: 1.0, lat: 2.0},
        zoom: 5,
        cluster: false,
        class: "h-64"
      )

    config = decode_config(html)
    assert config["center"] == %{"lng" => 1.0, "lat" => 2.0}
    assert config["zoom"] == 5
    assert config["cluster"] == false
    assert html =~ ~s(class="phx-maplibre h-64")
  end

  test "global rest attributes pass through" do
    html = render_map(id: "m3", "data-testid": "the-map")
    assert html =~ ~s(data-testid="the-map")
  end

  test "id is required" do
    assert_raise KeyError, fn -> render_map(zoom: 5) end
  end

  describe "config validation" do
    test "events must be a list of atoms" do
      for events <- [nil, "ready", [:ready, "move_end"], %{}] do
        assert_raise ArgumentError, ~r/events must be a list of atoms/, fn ->
          render_map(id: "m1", events: events)
        end
      end
    end

    test "center must carry numeric lng/lat" do
      for center <- [nil, %{}, %{lng: 1.0}, %{lng: self(), lat: 2.0}, %{"lng" => 1, "lat" => 2}] do
        assert_raise ArgumentError, ~r/center must be/, fn ->
          render_map(id: "m1", center: center)
        end
      end
    end

    test "zoom and move_end_throttle_ms must be numbers" do
      assert_raise ArgumentError, ~r/zoom must be a number/, fn ->
        render_map(id: "m1", zoom: "eleven")
      end

      assert_raise ArgumentError, ~r/move_end_throttle_ms must be a number/, fn ->
        render_map(id: "m1", move_end_throttle_ms: nil)
      end
    end

    test "an empty events list is fine" do
      assert decode_config(render_map(id: "m1", events: []))["events"] == []
    end
  end
end
