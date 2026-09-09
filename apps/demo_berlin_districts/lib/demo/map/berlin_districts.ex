defmodule Demo.Map.BerlinDistricts do
  @moduledoc false

  @palette ~w(
    #6366f1
    #ec4899
    #f59e0b
    #10b981
    #3b82f6
    #ef4444
    #8b5cf6
    #f97316
    #14b8a6
    #84cc16
  )

  defp pick_color(id) do
    Enum.at(@palette, :erlang.phash2(id, length(@palette)))
  end

  @url "https://gist.githubusercontent.com/chaudum/e8097ab9873ec71666b2/raw/835a8ba62166ca75bd4eb626eaf8b776430f90d8/Berlin.json"

  def fetch do
    case Req.get(url: @url, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, normalize(body)}

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, normalize_from_map(body)}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, feature} when is_map(feature) -> [to_area_feature(feature)]
        _ -> []
      end
    end)
  end

  defp normalize_from_map(%{"features" => features}) do
    Enum.map(features, &to_area_feature/1)
  end

  defp normalize_from_map(feature) when is_map(feature) do
    [to_area_feature(feature)]
  end

  defp to_area_feature(feature) do
    props = Map.get(feature, "properties", %{})
    geom = Map.get(feature, "geometry", %{})

    name =
      Map.get(props, "localname") ||
        Map.get(props, "name") ||
        Map.get(props, "Gemeinde_name") ||
        "District"

    id_val = Map.get(props, "id", Map.get(feature, "id", ""))
    district_id = "district_" <> to_string(id_val)

    %{
      id: district_id,
      type: "Feature",
      geometry: %{
        type: Map.get(geom, "type", "Polygon"),
        coordinates: Map.get(geom, "coordinates", [])
      },
      properties: %{
        "id" => district_id,
        "title" => name,
        "fill-color" => pick_color(district_id),
        "fill-opacity" => 0.25
      }
    }
  end
end
