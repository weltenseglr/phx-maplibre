defmodule Demo.Map do
  @moduledoc """
  Map domain context.

  Acts as the backend-agnostic boundary between the map UI component
  and any future data backend (Ash resources, external APIs, etc.).

  Phase 1 uses mock data via `Demo.Map.MockData`.
  Future phases will swap implementations behind the same function contracts.
  """

  alias Demo.Map.MockData

  @default_center %{lat: 52.52, lng: 13.405}
  @default_zoom 11
  @default_radius_m 20_000

  # --- Configuration ---

  @doc "Default center coordinates (Berlin Mitte) used as geolocation fallback."
  def default_center, do: @default_center

  @doc "Default zoom level for initial map view."
  def default_zoom, do: @default_zoom

  @doc "Default search radius in meters (~20 km)."
  def default_radius_m, do: @default_radius_m

  # --- Query adapter boundary ---

  @doc """
  Search features within a bounding box.

  Returns a `{point_features, area_features}` tuple where each element
  is a list of GeoJSON-compatible feature maps.

  This is the stable query boundary that future Ash adapters will implement.
  """
  def search_by_bounds(north, east, south, west, _opts \\ []) do
    MockData.features_in_bounds(north, east, south, west)
  end

  @doc """
  Search features within a center-point-plus-radius.

  `radius_m` is in meters. Returns the same `{point_features, area_features}` tuple.
  """
  def search_by_center_radius(lat, lng, radius_m, _opts \\ []) do
    MockData.features_within_radius(lat, lng, radius_m)
  end

  # --- Feature adapter boundary ---

  @doc """
  Convert domain entities into GeoJSON FeatureCollection maps
  suitable for `set_features` / `set_area_features` commands.
  """
  def to_point_feature_collection(features) do
    %{
      type: "FeatureCollection",
      features: Enum.map(features, &MockData.to_point_feature/1)
    }
  end

  def to_area_feature_collection(areas) do
    %{
      type: "FeatureCollection",
      features: Enum.map(areas, &MockData.to_area_feature/1)
    }
  end
end
