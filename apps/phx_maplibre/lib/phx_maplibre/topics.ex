defmodule PhxMaplibre.Topics do
  @moduledoc """
  Topic names for the per-map PubSub contract.

  Every map gets two topics, derived from its DOM id:

    * `"#{PhxMaplibre.Config.default_topic_prefix()}:{map_id}:events"` — all
      `%PhxMaplibre.Event{}` structs the map emits (gated by the component's
      `events` whitelist).
    * `"#{PhxMaplibre.Config.default_topic_prefix()}:{map_id}:commands"` —
      `%PhxMaplibre.Command{}` structs, which any process may broadcast to
      drive the map.

  One events topic per map, not one per kind of event: subscribers narrow
  things down by pattern matching on `%PhxMaplibre.Event{event: ...}` instead.
  Keeping the volume down is the sender's job — an event the component's
  `events` attribute doesn't list never leaves the browser.

  Change the `"phx_maplibre"` prefix globally with

      config :phx_maplibre, topic_prefix: "my_prefix"

  or per call with the `:topic_prefix` option.
  """

  @doc """
  The events topic for `map_id`.

      iex> PhxMaplibre.Topics.events_topic("berlin-map")
      "phx_maplibre:berlin-map:events"
  """
  @spec events_topic(String.t(), String.t()) :: String.t()
  def events_topic(map_id, prefix \\ PhxMaplibre.Config.default_topic_prefix())
      when is_binary(map_id) and is_binary(prefix) do
    "#{prefix}:#{map_id}:events"
  end

  @doc """
  The commands topic for `map_id`.

      iex> PhxMaplibre.Topics.commands_topic("berlin-map")
      "phx_maplibre:berlin-map:commands"
  """
  @spec commands_topic(String.t(), String.t()) :: String.t()
  def commands_topic(map_id, prefix \\ PhxMaplibre.Config.default_topic_prefix())
      when is_binary(map_id) and is_binary(prefix) do
    "#{prefix}:#{map_id}:commands"
  end
end
