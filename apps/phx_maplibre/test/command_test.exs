defmodule PhxMaplibre.CommandTest do
  use ExUnit.Case, async: true

  alias PhxMaplibre.Command

  describe "new/3" do
    test "validates set_features" do
      assert {:ok, %Command{command: :set_features}} =
               Command.new("m1", :set_features, %{geojson: %{type: "FeatureCollection", features: []}})

      assert {:error, {:invalid_params, :set_features}} = Command.new("m1", :set_features, %{})
    end

    test "validates fly_to" do
      assert {:ok, %Command{}} =
               Command.new("m1", :fly_to, %{
                 center: %{lng: 1.0, lat: 2.0},
                 zoom: 14,
                 duration: 1500
               })

      assert {:error, {:invalid_params, :fly_to}} =
               Command.new("m1", :fly_to, %{center: %{lng: "x", lat: 2.0}, zoom: 14, duration: 1})
    end

    test "validates fit_bounds" do
      assert {:ok, %Command{}} =
               Command.new("m1", :fit_bounds, %{
                 bounds: %{west: 1, south: 2, east: 3, north: 4},
                 padding: 40,
                 max_zoom: 15
               })

      assert {:error, {:invalid_params, :fit_bounds}} =
               Command.new("m1", :fit_bounds, %{bounds: %{}, padding: 40, max_zoom: 15})
    end

    test "validates set_style and request_geolocation" do
      assert {:ok, %Command{}} = Command.new("m1", :set_style, %{style: "https://example.com/s.json"})
      assert {:error, {:invalid_params, :set_style}} = Command.new("m1", :set_style, %{style: 42})
      assert {:ok, %Command{}} = Command.new("m1", :request_geolocation, %{})

      assert {:error, {:invalid_params, :request_geolocation}} =
               Command.new("m1", :request_geolocation, %{extra: true})
    end

    test "rejects unknown commands" do
      assert {:error, {:unknown_command, :warp}} = Command.new("m1", :warp, %{})
    end
  end

  describe "geojson validation" do
    @feature %{"type" => "Feature", "geometry" => %{"type" => "Point", "coordinates" => [1, 2]}}

    test "accepts FeatureCollections with either key style" do
      for command <- [:set_features, :set_area_features],
          geojson <- [
            %{"type" => "FeatureCollection", "features" => [@feature]},
            %{type: "FeatureCollection", features: [%{type: "Feature", geometry: nil}]},
            %{type: "FeatureCollection", features: []}
          ] do
        assert {:ok, %Command{}} = Command.new("m1", command, %{geojson: geojson})
      end
    end

    test "rejects anything that is not a FeatureCollection of Features" do
      for geojson <- [
            %{},
            %{"type" => "FeatureCollection"},
            %{"type" => "FeatureCollection", "features" => %{}},
            %{"type" => "Feature", "geometry" => nil},
            %{"type" => "FeatureCollection", "features" => [%{"type" => "Point"}]},
            %{"type" => "FeatureCollection", "features" => ["nope"]},
            "not geojson",
            nil
          ] do
        assert {:error, :invalid_geojson} =
                 Command.new("m1", :set_features, %{geojson: geojson}),
               "expected #{inspect(geojson)} to be rejected"

        assert {:error, :invalid_geojson} =
                 Command.new("m1", :set_area_features, %{geojson: geojson})
      end
    end

    test "new!/3 raises a one-line error without dumping the features" do
      big = %{type: "FeatureCollection", features: [%{"type" => "Point", "junk" => "x"}]}

      error =
        assert_raise ArgumentError, fn ->
          Command.new!("m1", :set_features, %{geojson: big})
        end

      assert error.message =~ "geojson must be a FeatureCollection map or a list of Feature maps"
      refute error.message =~ "junk"
    end
  end

  describe "new!/3" do
    test "returns the command on success" do
      assert %Command{map_id: "m1"} = Command.new!("m1", :set_style, %{style: "s"})
    end

    test "raises on invalid params" do
      assert_raise ArgumentError, ~r/invalid PhxMaplibre command/, fn ->
        Command.new!("m1", :fly_to, %{center: nil})
      end
    end
  end
end
