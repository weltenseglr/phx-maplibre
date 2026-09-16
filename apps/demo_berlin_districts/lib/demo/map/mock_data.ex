defmodule Demo.Map.MockData do
  @moduledoc """
  Mock data provider for phase 1.

  Generates venues and POIs around Berlin to exercise clustering,
  polygon overlays, and map interactions with realistic data volumes
  (hundreds of points).

  This module implements the query adapter and feature adapter contracts.
  Future Ash adapters will replace these functions with database-backed queries.
  """

  # Venues around Berlin neighborhoods
  @venues [
    {"Studio Mitte", "Mitte", 13.4050, 52.5230, "venue", "yoga"},
    {"Fitness Box Prenzlauer Berg", "Prenzlauer Berg", 13.4240, 52.5370, "venue", "gym"},
    {"Yoga Flow Kreuzberg", "Kreuzberg", 13.4170, 52.4990, "venue", "yoga"},
    {"Climb Hall Friedrichshain", "Friedrichshain", 13.4530, 52.5160, "venue", "climbing"},
    {"Pilates Studio Charlottenburg", "Charlottenburg", 13.3040, 52.5170, "venue", "pilates"},
    {"CrossFit Neukoelln", "Neukoelln", 13.4350, 52.4810, "venue", "crossfit"},
    {"Swim Center Wilmersdorf", "Wilmersdorf", 13.3170, 52.4870, "venue", "swimming"},
    {"Tennis Club Steglitz", "Steglitz", 13.3230, 52.4560, "venue", "tennis"},
    {"Bouldering Wedding", "Wedding", 13.3610, 52.5490, "venue", "climbing"},
    {"Dance Studio Schoeneberg", "Schoeneberg", 13.3520, 52.4960, "venue", "dance"},
    {"Boxing Gym Tempelhof", "Tempelhof", 13.3860, 52.4680, "venue", "boxing"},
    {"Martial Arts Spandau", "Spandau", 13.2010, 52.5360, "venue", "martial_arts"},
    {"Cycling Studio Mitte", "Mitte", 13.3980, 52.5190, "venue", "cycling"},
    {"HIIT Lab Kreuzberg", "Kreuzberg", 13.4250, 52.5030, "venue", "hiit"},
    {"Reform Studio Mitte", "Mitte", 13.4100, 52.5250, "venue", "pilates"},
    {"Spin Zone Prenzlauer Berg", "Prenzlauer Berg", 13.4300, 52.5340, "venue", "cycling"},
    {"Aerial Arts Friedrichshain", "Friedrichshain", 13.4480, 52.5130, "venue", "dance"},
    {"F45 Training Mitte", "Mitte", 13.3890, 52.5210, "venue", "hiit"},
    {"Rumble Boxing Charlottenburg", "Charlottenburg", 13.2980, 52.5100, "venue", "boxing"},
    {"Gold's Gym Neukoelln", "Neukoelln", 13.4410, 52.4840, "venue", "gym"}
  ]

  # Separate entities sharing one building entrance, used to exercise cluster
  # spiderfying without relying on random jitter.
  @overlapping_venues [
    {"Shared Entrance Yoga", "Mitte", 13.4050, 52.5200, "venue", "yoga"},
    {"Shared Entrance Pilates", "Mitte", 13.4050, 52.5200, "venue", "pilates"},
    {"Shared Entrance Boxing", "Mitte", 13.4050, 52.5200, "venue", "boxing"}
  ]

  # Service area polygons
  @areas [
    %{
      id: "area_mitte",
      title: "Mitte Coverage Area",
      style_variant: "service_area",
      coordinates: [
        [13.39, 52.51],
        [13.42, 52.51],
        [13.42, 52.53],
        [13.39, 52.53],
        [13.39, 52.51]
      ]
    },
    %{
      id: "area_kreuzberg",
      title: "Kreuzberg Coverage Area",
      style_variant: "coverage",
      coordinates: [
        [13.40, 52.49],
        [13.44, 52.49],
        [13.44, 52.51],
        [13.40, 52.51],
        [13.40, 52.49]
      ]
    }
  ]

  # POI landmarks
  @pois [
    {"Brandenburg Gate", "Mitte", 13.3777, 52.5163, "poi", "landmark"},
    {"TV Tower", "Mitte", 13.4094, 52.5208, "poi", "landmark"},
    {"Tempelhofer Feld", "Tempelhof", 13.4050, 52.4730, "poi", "park"},
    {"Tiergarten", "Tiergarten", 13.3500, 52.5145, "poi", "park"},
    {"Mauerpark", "Prenzlauer Berg", 13.4020, 52.5450, "poi", "park"},
    {"Viktoriapark", "Kreuzberg", 13.3620, 52.4930, "poi", "park"},
    {"Gloeckner Park", "Friedrichshain", 13.4460, 52.5120, "poi", "park"},
    {"East Side Gallery", "Friedrichshain", 13.4430, 52.5070, "poi", "landmark"}
  ]

  @doc """
  Return all venues as domain entities, plus 8 jittered duplicates per base
  venue and 3 exact-coordinate fixtures (183 points total).
  """
  def all_venues do
    # Base venues + jittered duplicates for density
    base = Enum.map(@venues, &venue_entity/1)
    jittered = generate_jittered(base, 8)
    overlapping = Enum.map(@overlapping_venues, &venue_entity/1)
    base ++ jittered ++ overlapping
  end

  @doc "Return all POIs as domain entities."
  def all_pois do
    Enum.map(@pois, &poi_entity/1)
  end

  @doc "Return all area features."
  def all_areas do
    @areas
  end

  @doc "All point entities (venues + POIs)."
  def all_points do
    all_venues() ++ all_pois()
  end

  # --- Query adapter implementations ---

  @doc """
  Filter features within a bounding box.
  Returns `{point_features, area_features}` tuple.
  """
  def features_in_bounds(north, east, south, west) do
    points =
      all_points()
      |> Enum.filter(fn e ->
        e.lat <= north && e.lat >= south && e.lng <= east && e.lng >= west
      end)
      |> Enum.map(&to_point_feature/1)

    areas =
      all_areas()
      |> Enum.filter(&area_in_bounds?(&1, north, east, south, west))
      |> Enum.map(&to_area_feature/1)

    {points, areas}
  end

  @doc """
  Filter features within a center-plus-radius.
  Returns `{point_features, area_features}` tuple.
  """
  def features_within_radius(lat, lng, radius_m) do
    points =
      all_points()
      |> Enum.filter(fn e ->
        haversine(lat, lng, e.lat, e.lng) <= radius_m
      end)
      |> Enum.map(&to_point_feature/1)

    areas =
      all_areas()
      |> Enum.map(&to_area_feature/1)

    {points, areas}
  end

  @doc "Convert a domain entity to a GeoJSON point feature map."
  def to_point_feature(entity) do
    %{
      id: entity.id,
      type: "Feature",
      geometry: %{
        type: "Point",
        coordinates: [entity.lng, entity.lat]
      },
      properties: %{
        id: entity.id,
        title: entity.title,
        description: entity.subtitle,
        kind: entity.type,
        category: entity.category
      }
    }
  end

  @doc "Convert an area definition to a GeoJSON polygon feature map."
  def to_area_feature(area) do
    %{
      id: area.id,
      type: "Feature",
      geometry: %{
        type: "Polygon",
        coordinates: [area.coordinates]
      },
      properties: %{
        title: area.title
      }
    }
  end

  # --- Private helpers ---

  defp venue_entity({title, subtitle, lng, lat, type, category}) do
    %{
      id: "venue_#{slug(title)}",
      title: title,
      subtitle: subtitle,
      lng: lng,
      lat: lat,
      type: type,
      category: category
    }
  end

  defp poi_entity({title, subtitle, lng, lat, type, category}) do
    %{
      id: "poi_#{slug(title)}",
      title: title,
      subtitle: subtitle,
      lng: lng,
      lat: lat,
      type: type,
      category: category
    }
  end

  defp slug(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp generate_jittered(base, count) do
    Enum.flat_map(base, fn entity ->
      Enum.map(1..count, fn i ->
        offset_lng = jitter_offset(entity.id, i, :lng)
        offset_lat = jitter_offset(entity.id, i, :lat)

        %{
          entity
          | id: "#{entity.id}_#{i}",
            title: "#{entity.title} #{i}",
            lng: entity.lng + offset_lng,
            lat: entity.lat + offset_lat
        }
      end)
    end)
  end

  defp jitter_offset(id, index, axis) do
    (:erlang.phash2({id, index, axis}, 601) - 300) / 10_000
  end

  defp area_in_bounds?(area, north, east, south, west) do
    # Check if any coordinate of the area is within bounds
    Enum.any?(area.coordinates, fn [_lng, lat] ->
      lat <= north && lat >= south
    end) or
      Enum.any?(area.coordinates, fn [lng, _lat] ->
        lng <= east && lng >= west
      end)
  end

  # Haversine distance in meters
  defp haversine(lat1, lon1, lat2, lon2) do
    r = 6_371_000

    dlat = deg2rad(lat2 - lat1)
    dlon = deg2rad(lon2 - lon1)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(deg2rad(lat1)) * :math.cos(deg2rad(lat2)) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))

    r * c
  end

  defp deg2rad(deg), do: deg * :math.pi() / 180
end
