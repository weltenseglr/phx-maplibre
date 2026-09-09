defmodule PhxMaplibre.Command do
  @moduledoc """
  A command that drives a map, as broadcast on the map's commands topic.

  Most code never touches this module: the `PhxMaplibre` facade
  (`PhxMaplibre.fly_to/3` and friends) builds and sends these for you. The
  constructors here check parameter shapes, so a malformed command fails at
  the sender instead of quietly doing nothing in JavaScript.

  ## Commands

  | command | params |
  |---|---|
  | `:set_features` | `%{geojson: feature_collection}` |
  | `:set_area_features` | `%{geojson: feature_collection}` |
  | `:fly_to` | `%{center: %{lng: lng, lat: lat}, zoom: zoom, duration: ms}` |
  | `:fit_bounds` | `%{bounds: %{west: w, south: s, east: e, north: n}, padding: px, max_zoom: z}` |
  | `:set_style` | `%{style: url}` |
  | `:request_geolocation` | `%{}` |

  The `geojson` of a features command has to be a FeatureCollection map (a
  `type` of `"FeatureCollection"`, string or atom key, and a list under
  `features`) whose entries are Feature maps. The check is structural only —
  geometries are the caller's business — but it does stop `%{}` and friends
  from reaching `setData` in the browser, where the failure would be silent.
  """

  @enforce_keys [:map_id, :command, :params]
  defstruct [:map_id, :command, :params, :meta]

  @typedoc "A command the browser hook understands."
  @type command_name ::
          :set_features
          | :set_area_features
          | :fly_to
          | :fit_bounds
          | :set_style
          | :request_geolocation

  @typedoc "A validated command broadcast to a single map's commands topic."
  @type t :: %__MODULE__{
          map_id: String.t(),
          command: command_name(),
          params: map(),
          meta: %{pid: pid(), at: DateTime.t()} | nil
        }

  @command_names [
    :set_features,
    :set_area_features,
    :fly_to,
    :fit_bounds,
    :set_style,
    :request_geolocation
  ]

  @doc """
  Every command name `new/3` will accept, as atoms.
  """
  @spec command_names() :: [command_name()]
  def command_names, do: @command_names

  @doc """
  Builds a validated command, stamped with the caller's pid and the current
  time.

  A known command whose params are the wrong shape gives
  `{:error, {:invalid_params, command}}`; a name that isn't a command at all
  gives `{:error, {:unknown_command, command}}`. A features command whose
  `geojson` is not a FeatureCollection gives `{:error, :invalid_geojson}`.
  """
  @spec new(String.t(), command_name(), map()) :: {:ok, t()} | {:error, term()}
  def new(map_id, command, params) when is_binary(map_id) and is_atom(command) do
    with :ok <- validate(command, params) do
      {:ok,
       %__MODULE__{
         map_id: map_id,
         command: command,
         params: params,
         meta: %{pid: self(), at: DateTime.utc_now()}
       }}
    end
  end

  @doc """
  Same as `new/3`, but raises `ArgumentError` instead of returning an error
  tuple. The message names the command, the map, and the params it choked on —
  except for `:invalid_geojson`, where the params are the whole feature dump
  and stay out of it.
  """
  @spec new!(String.t(), command_name(), map()) :: t()
  def new!(map_id, command, params) do
    case new(map_id, command, params) do
      {:ok, cmd} ->
        cmd

      {:error, :invalid_geojson} ->
        raise ArgumentError,
              "invalid PhxMaplibre command #{inspect(command)} for map #{inspect(map_id)}: " <>
                "geojson must be a FeatureCollection map or a list of Feature maps"

      {:error, reason} ->
        raise ArgumentError,
              "invalid PhxMaplibre command #{inspect(command)} for map #{inspect(map_id)}: " <>
                "#{inspect(reason)} (params: #{inspect(params)})"
    end
  end

  defp validate(command, %{geojson: geojson})
       when command in [:set_features, :set_area_features] do
    if feature_collection?(geojson), do: :ok, else: {:error, :invalid_geojson}
  end

  defp validate(:fly_to, %{center: %{lng: lng, lat: lat}, zoom: zoom, duration: duration})
       when is_number(lng) and is_number(lat) and is_number(zoom) and is_number(duration),
       do: :ok

  defp validate(:fit_bounds, %{
         bounds: %{west: west, south: south, east: east, north: north},
         padding: padding,
         max_zoom: max_zoom
       })
       when is_number(west) and is_number(south) and is_number(east) and is_number(north) and
              is_number(padding) and is_number(max_zoom),
       do: :ok

  defp validate(:set_style, %{style: style}) when is_binary(style), do: :ok

  defp validate(:request_geolocation, params) when params == %{}, do: :ok

  defp validate(command, _params) when command in @command_names,
    do: {:error, {:invalid_params, command}}

  defp validate(command, _params), do: {:error, {:unknown_command, command}}

  # Structural only: a FeatureCollection carrying a list of Features. What is
  # inside a Feature — geometry, properties, paint overrides — is not our call.
  defp feature_collection?(%{} = geojson) do
    case member(geojson, :features) do
      features when is_list(features) ->
        member(geojson, :type) == "FeatureCollection" and Enum.all?(features, &feature?/1)

      _other ->
        false
    end
  end

  defp feature_collection?(_geojson), do: false

  defp feature?(%{} = feature), do: member(feature, :type) == "Feature"
  defp feature?(_other), do: false

  defp member(map, key) do
    case map do
      %{^key => value} -> value
      _ -> Map.get(map, Atom.to_string(key))
    end
  end
end
