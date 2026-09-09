defmodule PhxMaplibre.LiveView do
  @moduledoc """
  The parent LiveView's half of the bridge: map events go out to PubSub,
  PubSub commands come back in to the map.

  `use PhxMaplibre.LiveView` in the LiveView that renders one or more
  `PhxMaplibre.Components.map/1` components, then register each map in
  `c:Phoenix.LiveView.mount/3`:

      defmodule MyAppWeb.TrackerLive do
        use MyAppWeb, :live_view
        use PhxMaplibre.LiveView

        def mount(_params, _session, socket) do
          {:ok, PhxMaplibre.LiveView.attach_map(socket, "tracker-map", pubsub: MyApp.PubSub)}
        end

        def handle_info(%PhxMaplibre.Event{event: :move_end, payload: %{bounds: bounds}}, socket) do
          ...
        end
      end

  From then on:

    * a whitelisted map interaction reaches the browser hook, is relayed
      through this LiveView, and goes out as a `%PhxMaplibre.Event{}` on the
      map's events topic. The LiveView receives it back through
      `handle_info/2` like any other subscriber, so you never write a
      `handle_event/3` clause for it;
    * any process can drive the map by broadcasting a `%PhxMaplibre.Command{}`
      on the map's commands topic (see the `PhxMaplibre` facade), and this
      LiveView turns it into a `push_event/3` to the hook.

  Both directions ride on `Phoenix.LiveView.attach_hook/4` and halt only on
  their own messages, so your existing `handle_event`/`handle_info` clauses
  keep working unchanged.

  ## Trusting the client

  The component's `events` whitelist runs in the browser, and a connected
  client can push whatever it wants over the channel. `attach_map/3` therefore
  takes its own `:events` allowlist — pass the same list you gave the
  component — and anything outside it is dropped with a warning. Payloads
  over the map's `:max_event_payload_bytes` limit (512 KB unless configured)
  are dropped too, before anything walks them. Apps whose features carry
  large properties — base64-encoded images, say — should raise the limit or
  pass `:infinity`: on a single node the broadcast shares large binaries
  rather than copying them per subscriber, so a higher limit is cheaper than
  it looks. The cap guards against fabricated payloads, not your own data.

  A hostile client can also repeat the same rejection at LiveView message
  rates, so each rejection reason is logged at most once every 10 seconds per
  LiveView process — repeats past that are silent in the logs but still
  counted: every drop fires `[:phx_maplibre, :event_dropped]` regardless of
  the throttle, so operators can see it happening even when the logs go
  quiet.

  ## Telemetry

    * `[:phx_maplibre, :event]` — a client event was relayed to PubSub.
      Metadata: `%{map_id: map_id, event: event_name}`.
    * `[:phx_maplibre, :command]` — a command was sent (see `PhxMaplibre`).
      Metadata: `%{map_id: map_id, command: command_name}`.
    * `[:phx_maplibre, :event_dropped]` — a client event was rejected before
      relay. Metadata: `%{map_id: map_id | nil, reason: reason}`, where
      `reason` is one of `:malformed`, `:unattached`, `:unknown_event`,
      `:invalid_payload`, `:disallowed_event`, `:oversized`. `map_id` is `nil` when the params
      were too malformed to trust an id from them.

  All three carry `%{system_time: System.system_time()}` as measurements.
  """

  require Logger

  alias PhxMaplibre.{Command, Config, Event, Topics}

  @registry_key :__phx_maplibre__

  # A client event is client input: only allowlisted names get relayed, and an
  # absurd payload is dropped before anything walks it.
  @default_max_payload_bytes 512 * 1024

  @doc """
  Installs the hooks that relay map events and commands for this LiveView.

  Use this once in the LiveView that renders a map, then call `attach_map/3`
  from `mount/3` for each map id. The hooks leave unrelated `handle_event/3`
  and `handle_info/2` messages alone.
  """
  defmacro __using__(_opts) do
    quote do
      on_mount {PhxMaplibre.LiveView, :default}
    end
  end

  @doc false
  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> Phoenix.Component.assign(@registry_key, Map.get(socket.assigns, @registry_key, %{}))
     |> Phoenix.LiveView.attach_hook(
       :phx_maplibre_events,
       :handle_event,
       &__MODULE__.handle_client_event/3
     )
     |> Phoenix.LiveView.attach_hook(
       :phx_maplibre_commands,
       :handle_info,
       &__MODULE__.handle_command_info/2
     )}
  end

  @doc """
  Registers a map with this LiveView and subscribes to its topics.

  Call it once per map, with the same id the component was given. Calling it
  again for an id already registered replaces the registration rather than
  stacking a second set of subscriptions.

  ## Options

    * `:pubsub` — the PubSub server. Falls back to
      `config :phx_maplibre, :pubsub`; one of the two is required.
    * `:topic_prefix` — see `PhxMaplibre.Topics`.
    * `:subscribe` — subscribe this LiveView to the map's events topic, so it
      receives `%PhxMaplibre.Event{}`s via `handle_info/2`. Defaults to `true`.
    * `:commands` — subscribe to the commands topic and act on
      `%PhxMaplibre.Command{}`s. Defaults to `true`.
    * `:events` — the events this map is allowed to relay, as atoms. Defaults
      to `PhxMaplibre.Event.default_event_names/0`. Pass the same list you
      give the component: the component's `events` whitelist only
      gates what the browser sends, and a connected client can push anything
      it likes over the channel regardless.
    * `:max_event_payload_bytes` — drop client event payloads larger than
      this many bytes (measured with `:erlang.external_size/1`). Defaults to
      `524_288` (512 KB). Pass a positive integer or `:infinity`. Raise it if
      your features legitimately carry large properties (embedded images and
      the like) that round-trip through `:feature_selected`.

  Subscribing requires a connected socket, so the dead mount only records the
  registration. Call it unconditionally in `mount/3`; the connected mount does
  the subscribing.
  """
  @spec attach_map(Phoenix.LiveView.Socket.t(), String.t(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def attach_map(%Phoenix.LiveView.Socket{} = socket, map_id, opts \\ [])
      when is_binary(map_id) do
    pubsub = Config.pubsub!(opts)
    prefix = Config.topic_prefix(opts)
    subscribe? = Keyword.get(opts, :subscribe, true)
    commands? = Keyword.get(opts, :commands, true)
    events = allowed_events(opts)
    max_payload = max_payload_bytes(opts)

    # Re-attaching must not leak (or duplicate) the previous subscriptions.
    socket = detach_map(socket, map_id)

    if Phoenix.LiveView.connected?(socket) do
      if subscribe?,
        do: :ok = Phoenix.PubSub.subscribe(pubsub, Topics.events_topic(map_id, prefix))

      if commands?,
        do: :ok = Phoenix.PubSub.subscribe(pubsub, Topics.commands_topic(map_id, prefix))
    end

    config = %{
      pubsub: pubsub,
      prefix: prefix,
      subscribe: subscribe?,
      commands: commands?,
      events: events,
      max_payload_bytes: max_payload
    }

    Phoenix.Component.assign(socket, @registry_key, Map.put(registry(socket), map_id, config))
  end

  defp allowed_events(opts) do
    case Keyword.get(opts, :events, Event.default_event_names()) do
      events when is_list(events) ->
        if Enum.all?(events, &is_atom/1) do
          MapSet.new(events)
        else
          raise ArgumentError,
                "PhxMaplibre.LiveView.attach_map/3: :events must be a list of atoms"
        end

      other ->
        raise ArgumentError,
              "PhxMaplibre.LiveView.attach_map/3: :events must be a list of atoms, " <>
                "got: #{inspect(other)}"
    end
  end

  @doc """
  Deregisters a map and unsubscribes from its topics.

  Needed when the map goes away but the LiveView process does not — a
  `live_patch` that swaps the map out, handled in `handle_params/3`. On a full
  navigation the process dies and takes the subscriptions with it. Passing an
  unregistered id returns the socket untouched.
  """
  @spec detach_map(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def detach_map(%Phoenix.LiveView.Socket{} = socket, map_id) when is_binary(map_id) do
    case Map.fetch(registry(socket), map_id) do
      {:ok, %{pubsub: pubsub, prefix: prefix}} ->
        if Phoenix.LiveView.connected?(socket) do
          Phoenix.PubSub.unsubscribe(pubsub, Topics.events_topic(map_id, prefix))
          Phoenix.PubSub.unsubscribe(pubsub, Topics.commands_topic(map_id, prefix))
        end

        Phoenix.Component.assign(socket, @registry_key, Map.delete(registry(socket), map_id))

      :error ->
        socket
    end
  end

  @doc false
  def handle_client_event("maplibre:event", params, socket) do
    case params do
      %{"id" => map_id, "event" => event_name, "payload" => payload}
      when is_binary(map_id) and is_binary(event_name) and is_map(payload) ->
        relay_event(socket, map_id, event_name, payload)

      _other ->
        drop_telemetry(nil, :malformed)

        warn_limited(:malformed, fn ->
          Logger.warning(
            "PhxMaplibre: malformed maplibre:event params: " <>
              inspect(params, limit: 20, printable_limit: 256)
          )
        end)
    end

    {:halt, socket}
  end

  def handle_client_event(_event, _params, socket), do: {:cont, socket}

  @doc false
  def handle_command_info(%Command{map_id: map_id} = command, socket) do
    case Map.fetch(registry(socket), map_id) do
      {:ok, %{commands: true}} ->
        {:halt,
         Phoenix.LiveView.push_event(
           socket,
           "maplibre:#{map_id}:#{command.command}",
           command.params
         )}

      {:ok, _config} ->
        {:halt, socket}

      :error ->
        # A command for a map this LiveView no longer (or never) registered —
        # best-effort cleanup of a stale default-configured subscription.
        unsubscribe_unknown(map_id)
        {:halt, socket}
    end
  end

  def handle_command_info(_message, socket), do: {:cont, socket}

  defp relay_event(socket, map_id, event_name, payload) do
    case Map.fetch(registry(socket), map_id) do
      {:ok, %{pubsub: pubsub, prefix: prefix} = config} ->
        cond do
          not known_event?(Event.event_names(), event_name) ->
            warn_unknown_event(event_name, map_id)

          not allowed_event?(config, event_name) ->
            drop_telemetry(map_id, :disallowed_event)

            warn_limited(:disallowed_event, fn ->
              Logger.warning(
                "PhxMaplibre: event #{inspect(event_name, printable_limit: 64)} is not in map " <>
                  "#{inspect(truncate_id(map_id))}'s :events allowlist — dropped"
              )
            end)

          oversized?(payload, config.max_payload_bytes) ->
            drop_telemetry(map_id, :oversized)

            warn_limited(:oversized, fn ->
              # Never log the payload itself; that is exactly what a flooder wants.
              Logger.warning(
                "PhxMaplibre: dropped oversized #{inspect(event_name, printable_limit: 64)} " <>
                  "payload from map #{inspect(truncate_id(map_id))} " <>
                  "(#{:erlang.external_size(payload)} bytes, limit " <>
                  "#{config.max_payload_bytes} — raise it via attach_map/3's " <>
                  ":max_event_payload_bytes)"
              )
            end)

          true ->
            broadcast_event(pubsub, prefix, map_id, event_name, payload)
        end

      :error ->
        drop_telemetry(map_id, :unattached)

        warn_limited(:unattached, fn ->
          Logger.warning(
            "PhxMaplibre: event #{inspect(event_name, printable_limit: 64)} from unattached " <>
              "map #{inspect(truncate_id(map_id))} — did you call " <>
              "PhxMaplibre.LiveView.attach_map/3 in mount?"
          )
        end)
    end
  end

  defp broadcast_event(pubsub, prefix, map_id, event_name, payload) do
    case Event.from_client(map_id, event_name, payload) do
      {:ok, event} ->
        :telemetry.execute(
          [:phx_maplibre, :event],
          %{system_time: System.system_time()},
          %{map_id: map_id, event: event.event}
        )

        Phoenix.PubSub.broadcast(pubsub, Topics.events_topic(map_id, prefix), event)

      {:error, :unknown_event} ->
        warn_unknown_event(event_name, map_id)

      {:error, :invalid_payload} ->
        drop_telemetry(map_id, :invalid_payload)

        warn_limited(:invalid_payload, fn ->
          Logger.warning(
            "PhxMaplibre: dropped invalid #{inspect(event_name, printable_limit: 64)} " <>
              "payload from map #{inspect(truncate_id(map_id))}"
          )
        end)
    end
  end

  defp warn_unknown_event(event_name, map_id) do
    drop_telemetry(map_id, :unknown_event)

    warn_limited(:unknown_event, fn ->
      Logger.warning(
        "PhxMaplibre: unknown event #{inspect(event_name, printable_limit: 64)} from map " <>
          "#{inspect(truncate_id(map_id))}"
      )
    end)
  end

  defp drop_telemetry(map_id, reason) do
    :telemetry.execute(
      [:phx_maplibre, :event_dropped],
      %{system_time: System.system_time()},
      %{map_id: map_id, reason: reason}
    )
  end

  # Rejection warnings run at LiveView message rates, so a hostile client can
  # flood the logs by repeating the same rejection. Throttle by reason per
  # process (the LiveView process is the natural scope) rather than dropping
  # the warning's information entirely — the telemetry event above still
  # fires every time regardless of this throttle.
  defp warn_limited(reason_key, fun) do
    key = {:phx_maplibre_warned, reason_key}
    now = System.monotonic_time(:millisecond)

    case Process.get(key) do
      last when is_integer(last) and now - last < 10_000 ->
        :ok

      _ ->
        Process.put(key, now)
        fun.()
    end
  end

  # Ids are client-echoed strings; bound them before they hit the logs so a
  # hostile client cannot pad one to flood log storage.
  defp truncate_id(id) when is_binary(id), do: String.slice(id, 0, 64)
  defp truncate_id(id), do: id

  # Both lists hold atoms; the wire name is a string, and no atom is ever
  # created from client input to compare them.
  defp allowed_event?(%{events: allowed}, event_name), do: known_event?(allowed, event_name)
  defp allowed_event?(_config, _event_name), do: true

  defp known_event?(names, event_name),
    do: Enum.any?(names, &(Atom.to_string(&1) == event_name))

  defp oversized?(_payload, :infinity), do: false
  defp oversized?(payload, limit), do: :erlang.external_size(payload) > limit

  defp max_payload_bytes(opts) do
    case Keyword.get(opts, :max_event_payload_bytes, @default_max_payload_bytes) do
      :infinity ->
        :infinity

      bytes when is_integer(bytes) and bytes > 0 ->
        bytes

      other ->
        raise ArgumentError,
              "PhxMaplibre.LiveView.attach_map/3: :max_event_payload_bytes must be a " <>
                "positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp unsubscribe_unknown(map_id) do
    if pubsub = Application.get_env(:phx_maplibre, :pubsub) do
      Phoenix.PubSub.unsubscribe(pubsub, Topics.commands_topic(map_id, Config.topic_prefix([])))
    end
  end

  defp registry(socket), do: Map.get(socket.assigns, @registry_key, %{})
end
