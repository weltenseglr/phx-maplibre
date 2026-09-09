defmodule PhxMaplibre.Config do
  @moduledoc """
  Configuration resolution for PhxMaplibre.

  Every setting resolves the same way: explicit option first, then application
  environment, then the built-in default — or a raise, where there is no
  sensible default to fall back on.

      # Global defaults, e.g. in config/config.exs of the host app:
      config :phx_maplibre,
        pubsub: MyApp.PubSub,
        topic_prefix: "phx_maplibre"
  """

  @default_topic_prefix "phx_maplibre"

  @doc """
  The PubSub server to use, taken from `opts[:pubsub]` or, failing that,
  `config :phx_maplibre, :pubsub`.

  There is no default; with neither set this raises `ArgumentError` showing
  both ways to supply one.
  """
  @spec pubsub!(keyword()) :: atom()
  def pubsub!(opts) when is_list(opts) do
    Keyword.get(opts, :pubsub) || Application.get_env(:phx_maplibre, :pubsub) ||
      raise ArgumentError, """
      no PubSub server configured for PhxMaplibre.

      Pass one explicitly:

          PhxMaplibre.LiveView.attach_map(socket, "my-map", pubsub: MyApp.PubSub)

      or configure a default:

          config :phx_maplibre, pubsub: MyApp.PubSub
      """
  end

  @doc """
  The topic prefix, taken from `opts[:topic_prefix]`, then
  `config :phx_maplibre, :topic_prefix`, then `"#{@default_topic_prefix}"`.
  """
  @spec topic_prefix(keyword()) :: String.t()
  def topic_prefix(opts) when is_list(opts) do
    Keyword.get(opts, :topic_prefix) ||
      Application.get_env(:phx_maplibre, :topic_prefix) ||
      @default_topic_prefix
  end

  @doc false
  @spec default_topic_prefix() :: String.t()
  def default_topic_prefix, do: @default_topic_prefix
end
