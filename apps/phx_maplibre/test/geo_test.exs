defmodule PhxMaplibre.GeoTest do
  use ExUnit.Case, async: true

  alias PhxMaplibre.Geo

  describe "bounds/1" do
    test "computes bounds from atom-keyed features" do
      features = [
        %{type: "Feature", geometry: %{type: "Point", coordinates: [13.4, 52.5]}},
        %{type: "Feature", geometry: %{type: "Point", coordinates: [13.6, 52.4]}}
      ]

      assert Geo.bounds(features) == {:ok, %{west: 13.4, south: 52.4, east: 13.6, north: 52.5}}
    end

    test "computes bounds from string-keyed GeoJSON" do
      geojson = %{
        "type" => "FeatureCollection",
        "features" => [
          %{
            "type" => "Feature",
            "geometry" => %{"type" => "Point", "coordinates" => [10.0, 50.0]}
          },
          %{
            "type" => "Feature",
            "geometry" => %{"type" => "Point", "coordinates" => [11.0, 51.0]}
          }
        ]
      }

      assert Geo.bounds(geojson) == {:ok, %{west: 10.0, south: 50.0, east: 11.0, north: 51.0}}
    end

    test "handles MultiPolygon nesting" do
      geometry = %{
        "type" => "MultiPolygon",
        "coordinates" => [
          [[[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 0.0]]],
          [[[2.0, 2.0], [3.0, 2.0], [3.0, 3.0], [2.0, 2.0]]]
        ]
      }

      assert Geo.bounds(geometry) == {:ok, %{west: 0.0, south: 0.0, east: 3.0, north: 3.0}}
    end

    test "walks a GeometryCollection" do
      geojson = %{
        "type" => "GeometryCollection",
        "geometries" => [
          %{"type" => "Point", "coordinates" => [1.0, 2.0]},
          %{"type" => "LineString", "coordinates" => [[3.0, 4.0], [5.0, 6.0]]}
        ]
      }

      assert Geo.bounds(geojson) == {:ok, %{west: 1.0, south: 2.0, east: 5.0, north: 6.0}}
    end

    test "walks a GeometryCollection nested in a Feature, atom keys included" do
      geojson = %{
        type: "FeatureCollection",
        features: [
          %{
            type: "Feature",
            geometry: %{
              type: "GeometryCollection",
              geometries: [
                %{type: "Point", coordinates: [10.0, 20.0]},
                %{
                  type: "GeometryCollection",
                  geometries: [%{type: "Point", coordinates: [-1.0, -2.0]}]
                }
              ]
            }
          }
        ]
      }

      assert Geo.bounds(geojson) == {:ok, %{west: -1.0, south: -2.0, east: 10.0, north: 20.0}}
    end

    test "falls back to bbox when there are no coordinates" do
      assert Geo.bounds(%{"type" => "FeatureCollection", "features" => [], "bbox" => [1, 2, 3, 4]}) ==
               {:ok, %{west: 1, south: 2, east: 3, north: 4}}

      assert Geo.bounds(%{type: "Feature", geometry: nil, bbox: [1.0, 2.0, 3.0, 4.0]}) ==
               {:ok, %{west: 1.0, south: 2.0, east: 3.0, north: 4.0}}
    end

    test "reads a 3D bbox off its horizontal elements" do
      geojson = %{"type" => "Feature", "bbox" => [1.0, 2.0, 100.0, 3.0, 4.0, 900.0]}

      assert Geo.bounds(geojson) == {:ok, %{west: 1.0, south: 2.0, east: 3.0, north: 4.0}}
    end

    test "prefers real coordinates over a bbox" do
      geojson = %{
        "type" => "Feature",
        "bbox" => [-90.0, -45.0, 90.0, 45.0],
        "geometry" => %{"type" => "Point", "coordinates" => [1.0, 2.0]}
      }

      assert Geo.bounds(geojson) == {:ok, %{west: 1.0, south: 2.0, east: 1.0, north: 2.0}}
    end

    test "ignores a garbage bbox instead of raising" do
      for bbox <- [
            ["a", "b", "c", "d"],
            [1, 2, 3],
            [1, 2, 3, nil],
            "1,2,3,4",
            %{"west" => 1},
            [[1, 2], [3, 4]]
          ] do
        assert Geo.bounds(%{"type" => "Feature", "bbox" => bbox}) == {:error, :no_coordinates}
      end
    end

    test "survives hostile coordinate members" do
      for coordinates <- [
            ["a", "b"],
            [%{"lng" => 1}, [nil, nil]],
            [[1, "x"], [nil, 2]],
            "13.4,52.5",
            [[[1, 2, 3, 4, 5]]]
          ] do
        assert Geo.bounds(%{"type" => "Point", "coordinates" => coordinates}) ==
                 {:error, :no_coordinates}
      end
    end

    test "returns an error for an empty list instead of crashing" do
      assert Geo.bounds([]) == {:error, :no_coordinates}
    end

    test "returns an error for a collection with no coordinates" do
      assert Geo.bounds(%{"type" => "FeatureCollection", "features" => []}) ==
               {:error, :no_coordinates}

      assert Geo.bounds(%{type: "Feature", geometry: nil}) == {:error, :no_coordinates}
    end
  end

  describe "feature_collection/1" do
    test "wraps features" do
      feature = %{type: "Feature"}

      assert Geo.feature_collection([feature]) == %{
               type: "FeatureCollection",
               features: [feature]
             }
    end
  end

  describe "within?/2" do
    @bounds %{west: 13.0, south: 52.0, east: 14.0, north: 53.0}

    test "point inside" do
      assert Geo.within?(%{lng: 13.5, lat: 52.5}, @bounds)
    end

    test "point outside" do
      refute Geo.within?(%{lng: 12.0, lat: 52.5}, @bounds)
      refute Geo.within?(%{lng: 13.5, lat: 51.0}, @bounds)
    end

    test "boundary is inclusive" do
      assert Geo.within?(%{lng: 13.0, lat: 52.0}, @bounds)
      assert Geo.within?(%{lng: 14.0, lat: 53.0}, @bounds)
    end

    test "antimeridian-crossing bounds wrap around" do
      wrapped = %{west: 170.0, south: -10.0, east: -170.0, north: 10.0}

      assert Geo.within?(%{lng: 179.5, lat: 0.0}, wrapped)
      assert Geo.within?(%{lng: -175.0, lat: 0.0}, wrapped)
      refute Geo.within?(%{lng: 0.0, lat: 0.0}, wrapped)
    end
  end
end
