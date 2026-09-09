defmodule PhxMaplibre.Geo do
  @moduledoc """
  Small GeoJSON helpers: bounding boxes, feature collections, and
  antimeridian-aware point-in-bounds checks.

  GeoJSON arguments may use string keys, as decoded from JSON, or atom keys,
  as built in Elixir. Missing, empty, or coordinate-free input is not an
  error here — `bounds/1` says so with `{:error, :no_coordinates}` rather than
  raising.
  """

  @typedoc "A geographic bounding box."
  @type bounds :: %{west: number(), south: number(), east: number(), north: number()}

  @typedoc "A GeoJSON map (Feature, any collection, or geometry) or a list of Features."
  @type geojson :: map() | [map()]

  @doc """
  Computes the bounding box of any GeoJSON value.

  Takes a FeatureCollection, a Feature, a GeometryCollection, a bare geometry,
  or a list of any of those, with string or atom keys either way. Nesting is
  followed all the way down: `features`, `geometry`, `geometries`, and the
  `coordinates` of every geometry type.

  An object that yields no coordinates of its own falls back to its `bbox`
  member, if it has a usable one — `[west, south, east, north]` or the 3D
  `[west, south, min_alt, east, north, max_alt]`, all numbers. A `bbox` that
  is anything else is ignored rather than trusted.

  When the walk turns up nothing at all — an empty list, an empty collection,
  null geometries — the result is `{:error, :no_coordinates}`.

      iex> PhxMaplibre.Geo.bounds(%{"type" => "Feature", "geometry" => %{"type" => "Point", "coordinates" => [13.4, 52.5]}})
      {:ok, %{west: 13.4, south: 52.5, east: 13.4, north: 52.5}}

      iex> PhxMaplibre.Geo.bounds([])
      {:error, :no_coordinates}
  """
  @spec bounds(geojson()) :: {:ok, bounds()} | {:error, :no_coordinates}
  def bounds(geojson) do
    case collect(geojson, []) do
      [] ->
        {:error, :no_coordinates}

      positions ->
        {west, east} = positions |> Enum.map(&elem(&1, 0)) |> Enum.min_max()
        {south, north} = positions |> Enum.map(&elem(&1, 1)) |> Enum.min_max()
        {:ok, %{west: west, south: south, east: east, north: north}}
    end
  end

  @doc """
  Wraps a list of Features into a GeoJSON FeatureCollection map.

  The Features are stored as given; nothing inside them is inspected.
  """
  @spec feature_collection([map()]) :: map()
  def feature_collection(features) when is_list(features) do
    %{type: "FeatureCollection", features: features}
  end

  @doc """
  Whether a point lies within a bounding box.

  Both arguments use atom keys. Bounds that cross the antimeridian
  (`west > east`) wrap around rather than describing an empty box, so there a
  longitude counts as inside when it is `>= west` **or** `<= east`.

      iex> PhxMaplibre.Geo.within?(%{lng: 179.5, lat: 0}, %{west: 170, south: -10, east: -170, north: 10})
      true
  """
  @spec within?(%{lng: number(), lat: number()}, bounds()) :: boolean()
  def within?(%{lng: lng, lat: lat}, %{west: west, south: south, east: east, north: north})
      when is_number(lng) and is_number(lat) do
    lat >= south and lat <= north and lng_within?(lng, west, east)
  end

  defp lng_within?(lng, west, east) when west <= east, do: lng >= west and lng <= east
  defp lng_within?(lng, west, east), do: lng >= west or lng <= east

  # Walks any GeoJSON shape collecting {lng, lat} tuples.
  defp collect(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect/2)
  end

  defp collect(%{} = map, acc) do
    case collect_members(map, acc) do
      # Nothing came out of the object itself — its bbox is the last resort.
      ^acc -> collect_bbox(map, acc)
      collected -> collected
    end
  end

  defp collect(_other, acc), do: acc

  defp collect_members(map, acc) do
    cond do
      coords = get(map, :coordinates) -> collect_coords(coords, acc)
      features = get(map, :features) -> collect(features, acc)
      geometries = get(map, :geometries) -> collect(geometries, acc)
      geometry = get(map, :geometry) -> collect(geometry, acc)
      true -> acc
    end
  end

  # [west, south, east, north] or the 3D [west, south, min, east, north, max].
  defp collect_bbox(map, acc) do
    case get(map, :bbox) do
      [west, south, east, north] -> bbox_corners(west, south, east, north, acc)
      [west, south, _min, east, north, _max] -> bbox_corners(west, south, east, north, acc)
      _other -> acc
    end
  end

  defp bbox_corners(west, south, east, north, acc)
       when is_number(west) and is_number(south) and is_number(east) and is_number(north) do
    [{west, south}, {east, north} | acc]
  end

  defp bbox_corners(_west, _south, _east, _north, acc), do: acc

  defp collect_coords([lng, lat | _] = position, acc)
       when is_number(lng) and is_number(lat) and length(position) <= 3 do
    [{lng, lat} | acc]
  end

  defp collect_coords(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_coords/2)
  end

  defp collect_coords(_other, acc), do: acc

  defp get(map, key) do
    case map do
      %{^key => value} -> value
      _ -> Map.get(map, Atom.to_string(key))
    end
  end
end
