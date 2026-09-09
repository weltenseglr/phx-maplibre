defmodule Mix.Tasks.GsdTracker.FetchLandCover do
  use Mix.Task

  @shortdoc "Fetches land cover data from GeoJSON and seeds LandCover table"
  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    geojson_path = geojson_path!()

    records =
      geojson_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.get("features", [])
      |> Enum.map(&build_record/1)
      |> Enum.reject(&is_nil/1)

    case Ash.bulk_create(records, GsdTracker.LandCover, :create,
           batch_size: 500,
           return_records?: true,
           return_errors?: true,
           domain: GsdTracker.Ash
         ) do
      %Ash.BulkResult{status: :success, records: created_records} ->
        Mix.shell().info("Inserted #{Enum.count(created_records)} LandCover records")

      %Ash.BulkResult{errors: errors} ->
        Mix.raise("Failed to insert LandCover records: #{inspect(errors, pretty: true)}")
    end
  end

  defp geojson_path! do
    path = Application.fetch_env!(:demo_gsd_tracker, :land_cover_geojson_path)

    candidates = resolve_paths(path)

    case Enum.find(candidates, &File.exists?/1) do
      nil ->
        Mix.raise(
          "GeoJSON file not found: #{path}. Run priv/scripts/extract_land_cover.sh first."
        )

      resolved_path ->
        resolved_path
    end
  end

  defp resolve_paths(path) do
    case Path.type(path) do
      :absolute -> [path]
      :relative -> relative_paths(path)
    end
  end

  defp relative_paths(path) do
    app_root = Path.expand("../../..", __DIR__)
    workspace_root = Path.expand("../..", app_root)

    [
      Path.expand(path, File.cwd!()),
      Path.expand(path, workspace_root),
      Path.expand(path, app_root)
    ]
  end

  defp build_record(%{"geometry" => geometry, "properties" => properties}) do
    with landuse_type when not is_nil(landuse_type) <- map_osm_tags(properties),
         geometry when not is_nil(geometry) <- build_geometry(geometry) do
      %{landuse_type: landuse_type, geometry: geometry, source: "osm"}
    end
  end

  defp build_record(_), do: nil

  defp map_osm_tags(%{"landuse" => "residential"}), do: :residential
  defp map_osm_tags(%{"landuse" => "commercial"}), do: :commercial
  defp map_osm_tags(%{"landuse" => "industrial"}), do: :industrial
  defp map_osm_tags(%{"landuse" => "retail"}), do: :retail
  defp map_osm_tags(%{"natural" => "water"}), do: :water
  defp map_osm_tags(_), do: nil

  defp build_geometry(%{"type" => "Polygon", "coordinates" => coordinates}) do
    %Geo.Polygon{coordinates: to_geo_coordinates(coordinates), srid: 4326}
  end

  defp build_geometry(%{"type" => "MultiPolygon", "coordinates" => coordinates}) do
    %Geo.MultiPolygon{coordinates: to_geo_coordinates(coordinates), srid: 4326}
  end

  defp build_geometry(_), do: nil

  defp to_geo_coordinates(list) when is_list(list) do
    if Enum.all?(list, &is_number/1) do
      List.to_tuple(list)
    else
      Enum.map(list, &to_geo_coordinates/1)
    end
  end
end
