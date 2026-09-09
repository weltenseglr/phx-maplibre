defmodule PhxMaplibre.EventTest do
  use ExUnit.Case, async: true

  alias PhxMaplibre.Event

  describe "from_client/3" do
    test "builds a validated event with atomized known keys" do
      assert {:ok, event} =
               Event.from_client("m1", "move_end", %{
                 "bounds" => %{"west" => 1, "south" => 2, "east" => 3, "north" => 4},
                 "center" => %{"lng" => 2.0, "lat" => 3.0},
                 "zoom" => 9
               })

      assert %Event{map_id: "m1", event: :move_end} = event
      assert event.payload.bounds == %{west: 1, south: 2, east: 3, north: 4}
      assert event.payload.center == %{lng: 2.0, lat: 3.0}
      assert event.payload.zoom == 9
      assert event.meta.pid == self()
      assert %DateTime{} = event.meta.at
    end

    test "rejects unknown event names without creating atoms" do
      assert Event.from_client("m1", "totally_made_up", %{}) == {:error, :unknown_event}
    end

    test "keeps unknown payload keys as strings" do
      payload = %{
        "bounds" => %{"west" => 1, "south" => 2, "east" => 3, "north" => 4},
        "center" => %{"lng" => 2.0, "lat" => 3.0},
        "zoom" => 9,
        "whatever" => 1
      }

      assert {:ok, event} = Event.from_client("m1", "ready", payload)
      assert event.payload["whatever"] == 1
    end

    test "does not touch keys inside properties" do
      assert {:ok, event} =
               Event.from_client("m1", "feature_selected", %{
                 "id" => "f1",
                "kind" => "point",
                "lng" => 13.4,
                "lat" => 52.5,
                "feature" => %{"type" => "Feature"},
                "properties" => %{"id" => "f1", "title" => "T", "lng" => 1}
               })

      assert event.payload.id == "f1"
      assert event.payload.properties == %{"id" => "f1", "title" => "T", "lng" => 1}
    end

    test "passes a GeoJSON feature through with string keys intact" do
      feature = %{
        "type" => "Feature",
        "id" => "f1",
        "geometry" => %{"type" => "Point", "coordinates" => [13.4, 52.5]},
        "properties" => %{"title" => "T", "circle-color" => "#f00"}
      }

      assert {:ok, event} =
               Event.from_client("m1", "feature_selected", %{
                 "id" => "f1",
                "kind" => "point",
                "lng" => 13.4,
                "lat" => 52.5,
                "feature" => feature
               })

      assert event.payload.feature == feature
      assert event.payload.kind == "point"
    end

    test "rejects a known event with a malformed payload" do
      assert Event.from_client("m1", "move_end", %{}) == {:error, :invalid_payload}
    end
  end

  test "event_names/0 covers the documented events" do
    names = Event.event_names()

    for name <- [
          :ready,
          :feature_selected,
          :feature_deselected,
          :feature_hovered,
          :feature_unhovered,
          :cluster_selected,
          :move_end,
          :geolocation_success,
          :geolocation_error
        ] do
      assert name in names
    end
  end
end
