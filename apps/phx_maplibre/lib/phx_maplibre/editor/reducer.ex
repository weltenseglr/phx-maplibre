defmodule PhxMaplibre.Editor.Reducer do
  @moduledoc "Pure authoritative feature operations with stable coordinate IDs and retained insertion anchors."
  def valid_mode?(mode, "Point"), do: mode in ["point", "marker", "text"]

  def valid_mode?(mode, "LineString"),
    do: mode in ["linestring", "line", "polyline", "freehand-linestring", "freehand-line"]

  def valid_mode?(mode, "Polygon"),
    do:
      mode in [
        "polygon",
        "rectangle",
        "angled-rectangle",
        "circle",
        "freehand",
        "sensor",
        "sector"
      ]

  def valid_mode?(_, _), do: false

  def id do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    Enum.map_join(
      [{a, 8}, {b, 4}, {Bitwise.bor(c, 0x4000), 4}, {Bitwise.bor(d, 0x8000), 4}, {e, 12}],
      "-",
      fn {value, width} ->
        value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
      end
    )
  end

  def create(feature, mode, ids \\ nil) do
    with %{"type" => "Feature", "geometry" => geometry} <- feature,
         :ok <- validate(geometry),
         coords <- coordinates(geometry),
         ids <- ids || Enum.map(coords, fn _ -> id() end),
         true <-
           is_list(ids) and length(ids) == length(coords) and
             Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..128)) and
             length(Enum.uniq(ids)) == length(ids),
         true <- valid_mode?(mode, geometry["type"]),
         true <- is_binary(feature["id"]) and byte_size(feature["id"]) in 1..128,
         true <- is_map(Map.get(feature, "properties", %{})),
         :ok <- validate_properties(Map.get(feature, "properties", %{})) do
      {nodes, _} =
        Enum.zip(coords, ids)
        |> Enum.map_reduce(nil, fn {coordinate, vertex_id}, anchor ->
          {%{
             "id" => vertex_id,
             "after" => anchor,
             "coordinate" => coordinate,
             "seed" => true,
             "deleted" => false,
             "version" => 0
           }, vertex_id}
        end)

      entry = %{
        feature: Map.put_new(feature, "properties", %{}),
        metadata: %{
          "mode" => mode,
          "nodes" => Map.new(nodes, &{&1["id"], &1}),
          "version" => 0,
          "acknowledgements" => %{},
          "property_versions" => %{},
          "mode_property_versions" => %{}
        }
      }

      {:ok, materialize(entry)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Invalid feature, mode, or coordinate IDs."}
    end
  end

  def edit(entry, operations) when is_list(operations) and length(operations) <= 1000 do
    Enum.reduce_while(operations, {:ok, entry}, fn op, {:ok, current} ->
      case operation(current, op) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, next} ->
        next = materialize(next)

        case validate(next.feature["geometry"]) do
          :ok -> {:ok, put_in(next.metadata["version"], entry.metadata["version"] + 1)}
          error -> error
        end

      error ->
        error
    end
  end

  def edit(_, _), do: {:error, "Invalid edit operations."}

  defp operation(entry, %{
         "type" => "mode_properties",
         "properties" => properties
       })
       when is_map(properties) do
    cond do
      entry.metadata["mode"] != "text" or Map.keys(properties) != ["text"] or
        not is_binary(properties["text"]) or byte_size(properties["text"]) > 10000 ->
        {:error, "Invalid text mode properties."}

      true ->
        versions =
          Map.update(entry.metadata["mode_property_versions"] || %{}, "text", 1, &(&1 + 1))

        {:ok,
         entry
         |> put_in(
           [:metadata, "properties"],
           Map.merge(entry.metadata["properties"] || %{}, properties)
         )
         |> put_in([:metadata, "mode_property_versions"], versions)}
    end
  end

  defp operation(entry, %{"type" => "properties", "properties" => properties})
       when is_map(properties) do
    with :ok <- validate_properties(properties) do
      versions =
        Enum.reduce(Map.keys(properties), entry.metadata["property_versions"] || %{}, fn key,
                                                                                         versions ->
          Map.update(versions, key, 1, &(&1 + 1))
        end)

      {:ok,
       entry
       |> put_in([:feature, "properties"], Map.merge(entry.feature["properties"], properties))
       |> put_in([:metadata, "property_versions"], versions)}
    end
  end

  defp operation(
         entry,
         %{"type" => "replace_geometry", "geometry" => geometry, "expected_version" => expected} =
           op
       ) do
    if expected == entry.metadata["version"] do
      with {:ok, replacement} <-
             create(
               Map.put(entry.feature, "geometry", geometry),
               entry.metadata["mode"],
               op["vertex_ids"]
             ) do
        {:ok,
         %{
           replacement
           | metadata:
               replacement.metadata
               |> Map.put("properties", entry.metadata["properties"] || %{})
               |> Map.put("property_versions", entry.metadata["property_versions"] || %{})
               |> Map.put("acknowledgements", entry.metadata["acknowledgements"])
         }}
      end
    else
      {:error, "Geometry changed concurrently; synchronize before replacing it."}
    end
  end

  defp operation(entry, %{"type" => "translate", "delta" => [dx, dy]})
       when is_number(dx) and is_number(dy) do
    nodes =
      Map.new(entry.metadata["nodes"], fn {id, node} ->
        [x, y] = node["coordinate"]

        {id,
         if(node["deleted"],
           do: node,
           else:
             node |> Map.put("coordinate", [x + dx, y + dy]) |> Map.update!("version", &(&1 + 1))
         )}
      end)

    {:ok, put_in(entry.metadata["nodes"], nodes)}
  end

  defp operation(entry, %{
         "type" => "insert",
         "vertex_id" => id,
         "after_id" => anchor,
         "coordinate" => coordinate
       }) do
    nodes = entry.metadata["nodes"]

    if is_binary(id) and byte_size(id) in 1..128 and coordinate?(coordinate) and
         (is_nil(anchor) or Map.has_key?(nodes, anchor)) and not Map.has_key?(nodes, id) and
         map_size(nodes) < 10000 do
      node = %{
        "id" => id,
        "after" => anchor,
        "coordinate" => coordinate,
        "seed" => false,
        "deleted" => false,
        "version" => 0
      }

      {:ok, put_in(entry.metadata["nodes"], Map.put(nodes, id, node))}
    else
      {:error, "Invalid coordinate or insertion anchor."}
    end
  end

  defp operation(entry, %{"type" => type, "vertex_id" => id} = op)
       when type in ["move", "remove"] do
    case entry.metadata["nodes"][id] do
      nil ->
        {:error, "The coordinate no longer exists."}

      node ->
        cond do
          node["deleted"] ->
            {:ok, entry}

          type == "move" and not coordinate?(op["coordinate"]) ->
            {:error, "Invalid coordinate."}

          true ->
            node =
              if type == "move",
                do: Map.put(node, "coordinate", op["coordinate"]),
                else: Map.put(node, "deleted", true)

            {:ok, put_in(entry.metadata["nodes"][id], Map.update!(node, "version", &(&1 + 1)))}
        end
    end
  end

  defp operation(_, _), do: {:error, "Unknown feature operation."}

  def materialize(entry) do
    children = Enum.group_by(Map.values(entry.metadata["nodes"]), & &1["after"])
    vertices = walk(children, nil) |> Enum.reject(& &1["deleted"])
    coords = Enum.map(vertices, & &1["coordinate"])

    geometry =
      case entry.feature["geometry"]["type"] do
        "Point" -> %{"type" => "Point", "coordinates" => List.first(coords)}
        "LineString" -> %{"type" => "LineString", "coordinates" => coords}
        "Polygon" -> %{"type" => "Polygon", "coordinates" => [coords ++ Enum.take(coords, 1)]}
      end

    entry
    |> put_in([:feature, "geometry"], geometry)
    |> put_in([:metadata, "vertex_ids"], Enum.map(vertices, & &1["id"]))
  end

  defp walk(children, anchor),
    do:
      Map.get(children, anchor, [])
      |> Enum.sort_by(&{&1["seed"], &1["id"]})
      |> Enum.flat_map(fn node -> [node | walk(children, node["id"])] end)

  def coordinates(%{"type" => "Point", "coordinates" => c}), do: [c]
  def coordinates(%{"type" => "LineString", "coordinates" => c}), do: c
  def coordinates(%{"type" => "Polygon", "coordinates" => [c]}), do: Enum.drop(c, -1)

  def validate(%{"type" => "Point", "coordinates" => c}),
    do: if(coordinate?(c), do: :ok, else: {:error, "Invalid point."})

  def validate(%{"type" => "LineString", "coordinates" => c})
      when is_list(c) and length(c) in 2..1000,
      do: if(Enum.all?(c, &coordinate?/1), do: :ok, else: {:error, "Invalid line coordinates."})

  def validate(%{"type" => "Polygon", "coordinates" => [ring]})
      when is_list(ring) and length(ring) in 4..1001 do
    if hd(ring) == List.last(ring) and Enum.all?(ring, &coordinate?/1) and
         length(Enum.uniq(Enum.drop(ring, -1))) == length(ring) - 1 and abs(area(ring)) > 1.0e-12 and
         not self_intersects?(ring), do: :ok, else: {:error, "Invalid closed polygon ring."}
  end

  def validate(_), do: {:error, "Use a point, line, or single-ring polygon."}

  def coordinate?([x, y]),
    do: is_number(x) and is_number(y) and x >= -180 and x <= 180 and y >= -90 and y <= 90

  def coordinate?(_), do: false

  defp area(ring),
    do:
      Enum.chunk_every(ring, 2, 1, :discard)
      |> Enum.reduce(0, fn [[x, y], [a, b]], sum -> sum + x * b - a * y end)

  defp validate_properties(properties) do
    cond do
      Map.has_key?(properties, "color") and
          not (is_binary(properties["color"]) and
                   Regex.match?(~r/^#[0-9a-fA-F]{6}$/, properties["color"])) ->
        {:error, "Invalid feature color."}

      Map.has_key?(properties, "name") and
          not (is_binary(properties["name"]) and String.length(properties["name"]) in 0..100) ->
        {:error, "Feature names must contain at most 100 characters."}

      true ->
        :ok
    end
  end

  defp self_intersects?(ring) do
    edges = Enum.chunk_every(ring, 2, 1, :discard) |> Enum.with_index()
    count = length(edges)

    Enum.any?(edges, fn {[a, b], i} ->
      Enum.any?(edges, fn {[c, d], j} ->
        cond do
          j <= i -> false
          j == i + 1 -> collinear_overlap?(a, b, d)
          i == 0 and j == count - 1 -> collinear_overlap?(b, a, c)
          true -> intersects?(a, b, c, d)
        end
      end)
    end)
  end

  defp cross([ax, ay], [bx, by], [cx, cy]), do: (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)

  defp on_segment?([ax, ay], [bx, by], [cx, cy]),
    do: cx >= min(ax, bx) and cx <= max(ax, bx) and cy >= min(ay, by) and cy <= max(ay, by)

  defp collinear_overlap?(a, b, c),
    do: abs(cross(a, b, c)) < 1.0e-14 and (on_segment?(a, b, c) or on_segment?(b, c, a))

  defp intersects?(a, b, c, d) do
    ab_c = cross(a, b, c)
    ab_d = cross(a, b, d)
    cd_a = cross(c, d, a)
    cd_b = cross(c, d, b)

    (ab_c * ab_d < 0 and cd_a * cd_b < 0) or
      (abs(ab_c) < 1.0e-14 and on_segment?(a, b, c)) or
      (abs(ab_d) < 1.0e-14 and on_segment?(a, b, d)) or
      (abs(cd_a) < 1.0e-14 and on_segment?(c, d, a)) or
      (abs(cd_b) < 1.0e-14 and on_segment?(c, d, b))
  end
end
