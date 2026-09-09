defmodule GsdTracker.Tracking do
  @moduledoc """
  Read-side context for GSD tracking data.

  Provides the last known position of every GSD so a freshly connected
  LiveView can render pins before the next simulation tick arrives.
  """

  require Logger

  alias GsdTracker.Repo

  @latest_positions_sql """
  SELECT DISTINCT ON (gsd_id)
         gsd_id,
         ST_Y(location) AS lat,
         ST_X(location) AS lng,
         status,
         flock_id,
         partner_id,
         speed_kmh,
         movement_vector,
         timestamp
  FROM gsd_stats
  ORDER BY gsd_id, timestamp DESC
  """

  @doc """
  Returns the latest known position per GSD.

  Shaped exactly like the positions broadcast on the `"gsd_updates"` topic.
  Returns `[]` when the query fails (fresh environments may have no data or
  no table yet).
  """
  def latest_positions do
    case Repo.query(@latest_positions_sql, []) do
      {:ok, %{rows: rows}} ->
        Enum.flat_map(rows, &to_position/1)

      {:error, error} ->
        Logger.debug("GsdTracker.Tracking.latest_positions/0 failed: #{inspect(error)}")
        []
    end
  rescue
    error ->
      Logger.debug("GsdTracker.Tracking.latest_positions/0 raised: #{inspect(error)}")
      []
  end

  defp to_position([_gsd_id, nil, _lng | _rest]), do: []
  defp to_position([_gsd_id, _lat, nil | _rest]), do: []

  defp to_position([
         gsd_id,
         lat,
         lng,
         status,
         flock_id,
         partner_id,
         speed_kmh,
         movement_vector,
         timestamp
       ]) do
    [
      %{
        gsd_id: uuid(gsd_id),
        lat: to_float(lat),
        lng: to_float(lng),
        status: status_atom(status),
        flock_id: uuid(flock_id),
        partner_id: uuid(partner_id),
        speed_kmh: to_float(speed_kmh),
        movement_vector: movement_vector(movement_vector),
        last_update_at: to_datetime(timestamp)
      }
    ]
  end

  defp to_position(_row), do: []

  defp uuid(nil), do: nil
  defp uuid(<<_::128>> = value), do: uuid_from_binary(value)
  defp uuid(value) when is_binary(value), do: value
  defp uuid(_value), do: nil

  defp uuid_from_binary(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp status_atom(nil), do: :unknown
  defp status_atom(status) when is_atom(status), do: status

  defp status_atom(status) when is_binary(status) do
    String.to_existing_atom(status)
  rescue
    ArgumentError -> :unknown
  end

  defp status_atom(_status), do: :unknown

  defp movement_vector(%{} = vector) do
    lat = vector_component(vector, :lat)
    lng = vector_component(vector, :lng)

    if is_nil(lat) or is_nil(lng), do: nil, else: %{lat: lat, lng: lng}
  end

  defp movement_vector(_vector), do: nil

  defp vector_component(vector, key) do
    vector
    |> Map.get(key, Map.get(vector, Atom.to_string(key)))
    |> to_float()
  end

  defp to_float(nil), do: nil
  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp to_float(_value), do: nil

  defp to_datetime(nil), do: nil
  defp to_datetime(%DateTime{} = value), do: value
  defp to_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp to_datetime(_value), do: nil
end
