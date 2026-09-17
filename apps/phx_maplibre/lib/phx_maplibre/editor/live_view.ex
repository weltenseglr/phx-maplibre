defmodule PhxMaplibre.Editor.LiveView do
  @moduledoc false
  alias PhxMaplibre.Editor.{Config, Document, Runtime}
  @key :__phx_maplibre_editors__

  def attach(socket, id, opts) when is_binary(id) and byte_size(id) > 0 do
    runtime = Keyword.fetch!(opts, :runtime)
    document_id = Keyword.fetch!(opts, :document_id)

    unless is_binary(document_id) and byte_size(document_id) in 1..256,
      do:
        raise(ArgumentError, "Editor document_id must be a nonempty string of at most 256 bytes")

    config =
      Config.normalize(
        Map.new(
          Keyword.take(opts, [:modes, :fields, :control, :control_options, :update_interval_ms])
        )
      )

    user = Keyword.get(opts, :user, %{}) |> Map.new(fn {k, v} -> {to_string(k), v} end)
    actor = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    user = Map.put_new(user, "color", "#" <> String.slice(actor, 0, 6))
    user = Map.put_new(user, "name", "Visitor " <> String.slice(actor, 0, 4))
    limit = Keyword.get(opts, :max_event_payload_bytes, 524_288)

    unless is_integer(limit) and limit > 0,
      do: raise(ArgumentError, "Editor payload limit must be positive")

    socket = detach(socket, id)
    socket = if Map.has_key?(socket.assigns, @key), do: socket, else: install_hooks(socket)

    registration = %{
      runtime: runtime,
      document_id: document_id,
      actor: actor,
      user: user,
      config: config,
      max_payload: limit
    }

    if Phoenix.LiveView.connected?(socket) do
      unless Enum.any?(registry(socket), fn {_, registration} ->
               registration.runtime == runtime and registration.document_id == document_id
             end) do
        :ok = Phoenix.PubSub.subscribe(Runtime.pubsub(runtime), Runtime.topic(document_id))
      end

      with {:ok, owner} <-
             Runtime.resolve(runtime, document_id,
               update_interval_ms: config["update_interval_ms"]
             ),
           do: Document.join(owner, actor, user)
    end

    Phoenix.Component.assign(socket, @key, Map.put(registry(socket), id, registration))
  end

  def detach(socket, id) do
    case Map.fetch(registry(socket), id) do
      {:ok, registration} ->
        if Phoenix.LiveView.connected?(socket) do
          with {:ok, owner} <- Runtime.resolve(registration.runtime, registration.document_id),
               do: Document.leave(owner, registration.actor)

          others = Map.delete(registry(socket), id)

          unless Enum.any?(others, fn {_, r} ->
                   r.runtime == registration.runtime and r.document_id == registration.document_id
                 end),
                 do:
                   Phoenix.PubSub.unsubscribe(
                     Runtime.pubsub(registration.runtime),
                     Runtime.topic(registration.document_id)
                   )
        end

        Phoenix.Component.assign(socket, @key, Map.delete(registry(socket), id))

      :error ->
        socket
    end
  end

  def handle_event(
        "maplibre:editor",
        %{"id" => id, "event" => event, "payload" => payload},
        socket
      )
      when is_binary(id) and is_binary(event) and is_map(payload) do
    reply =
      case Map.fetch(registry(socket), id) do
        {:ok, registration} ->
          if :erlang.external_size(payload) <= registration.max_payload do
            dispatch(registration, event, payload)
          else
            %{error: "Editor payload exceeds the configured limit."}
          end

        :error ->
          %{error: "This editor is not registered."}
      end

    {:halt, reply, socket}
  end

  def handle_event("maplibre:editor", _, socket),
    do: {:halt, %{error: "Invalid editor event."}, socket}

  def handle_event(_, _, socket), do: {:cont, socket}

  def handle_info({:phx_maplibre_editor, document_id, event, payload}, socket)
      when event in [:snapshot, :presence] do
    socket =
      Enum.reduce(registry(socket), socket, fn {id, r}, socket ->
        if r.document_id == document_id do
          Phoenix.LiveView.push_event(socket, "maplibre:editor:#{id}:#{event}", payload)
        else
          socket
        end
      end)

    {:halt, socket}
  end

  def handle_info(_, socket), do: {:cont, socket}

  defp dispatch(r, event, payload) do
    with {:ok, owner} <-
           Runtime.resolve(r.runtime, r.document_id,
             update_interval_ms: r.config["update_interval_ms"]
           ) do
      # Joining is idempotent and also restores presence after owner restart.
      joined = Document.join(owner, r.actor, r.user)

      result =
        case event do
          "sync" ->
            joined

          "mutate" ->
            if payload["action"] == "create" and payload["mode"] not in r.config["modes"],
              do: Map.put(flatten(joined), :error, "This drawing mode is not enabled."),
              else: Document.mutate(owner, r.actor, payload)

          "presence" ->
            Document.presence(owner, r.actor, payload)

          "settings" ->
            Document.settings(owner, r.actor, payload)

          "undo" ->
            Document.undo(owner, r.actor)

          "redo" ->
            Document.redo(owner, r.actor)

          _ ->
            %{error: "Unknown editor event."}
        end

      flatten(result)
      |> Map.merge(%{
        actor_id: r.actor,
        viewer_id: r.user["id"] || r.actor,
        color: r.user["color"]
      })
    else
      {:error, reason} -> %{error: "Document owner unavailable: #{inspect(reason)}"}
    end
  catch
    :exit, _ -> %{error: "Document owner unavailable. Synchronize before editing again."}
  end

  defp flatten(%{snapshot: snapshot} = reply),
    do: Map.merge(snapshot, Map.delete(reply, :snapshot))

  defp flatten(reply) when is_map(reply), do: reply
  defp flatten({:error, reason}), do: %{error: inspect(reason)}
  defp flatten(:ok), do: %{}

  defp install_hooks(socket) do
    socket
    |> Phoenix.Component.assign(@key, %{})
    |> Phoenix.LiveView.attach_hook(:phx_maplibre_editor_events, :handle_event, &handle_event/3)
    |> Phoenix.LiveView.attach_hook(:phx_maplibre_editor_updates, :handle_info, &handle_info/2)
  end

  defp registry(socket), do: Map.get(socket.assigns, @key, %{})
end
