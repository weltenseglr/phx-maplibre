defmodule PhxMaplibre.Editor.Document do
  @moduledoc "Authoritative document owner. Durable changes persist before acknowledgement and publication; presence is ephemeral."
  use GenServer
  alias PhxMaplibre.Editor.{Reducer, Runtime}
  def start(opts), do: GenServer.start(__MODULE__, opts)
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def snapshot(pid), do: GenServer.call(pid, :snapshot)
  def join(pid, actor, display), do: GenServer.call(pid, {:join, actor, display})
  def mutate(pid, actor, params), do: GenServer.call(pid, {:mutate, actor, params})
  def presence(pid, actor, params), do: GenServer.call(pid, {:presence, actor, params})
  def settings(pid, actor, params), do: GenServer.call(pid, {:settings, actor, params})
  def undo(pid, actor), do: GenServer.call(pid, {:history, actor, :undo})
  def redo(pid, actor), do: GenServer.call(pid, {:history, actor, :redo})
  def leave(pid, actor), do: GenServer.call(pid, {:leave, actor})
  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :document_id)

    fresh = %{
      document_id: id,
      generation: Reducer.id(),
      revision: 0,
      features: %{},
      deleted: %{},
      settings: %{update_interval_ms: initial_interval(opts)},
      receipts: %{}
    }

    storage = Keyword.get(opts, :storage)

    loaded =
      case storage do
        nil -> {:ok, nil}
        {module, config} -> module.load(id, config)
      end

    case loaded do
      {:ok, durable} ->
        {:ok,
         %{
           durable: normalize(durable || fresh),
           storage: storage,
           pubsub: Keyword.get(opts, :pubsub),
           presence: %{},
           sessions: %{},
           history: %{},
           opts: opts
         }}

      {:error, reason} ->
        {:stop, {:storage_load_failed, reason}}
    end
  end

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, public(state), state}

  def handle_call({:join, actor, display}, {pid, _}, state) do
    cond do
      match?(%{pid: ^pid}, state.sessions[actor]) ->
        {:reply, reply(state, actor), state}

      is_binary(actor) and byte_size(actor) in 1..128 and is_map(display) and
          not Map.has_key?(state.sessions, actor) ->
        entry = Map.take(display, [:name, :color, "name", "color"]) |> Map.put(:actor_id, actor)

        state = %{
          state
          | sessions: Map.put(state.sessions, actor, %{pid: pid, monitor: Process.monitor(pid)}),
            presence: Map.put(state.presence, actor, entry),
            history: Map.delete(state.history, actor)
        }

        broadcast_presence(state, actor, entry)
        {:reply, reply(state, actor), state}

      true ->
        {:reply, error(state, actor, "Invalid or already owned editor actor."), state}
    end
  end

  def handle_call({:leave, actor}, from, state) do
    if authorized?(state, actor, from) do
      state = remove_actor(state, actor)
      {:reply, reply(state, actor), state}
    else
      {:reply, error(state, actor, "Editor actor is not bound to this process."), state}
    end
  end

  def handle_call({kind, actor, params}, from, state)
      when kind in [:mutate, :presence, :settings] do
    if authorized?(state, actor, from) and is_map(params) and
         byte_size(:erlang.term_to_binary(params)) <=
           Keyword.get(state.opts, :max_payload_bytes, 262_144) do
      case kind do
        :presence -> update_presence(state, actor, params)
        :settings -> update_settings(state, actor, params)
        :mutate -> mutation(state, actor, params)
      end
    else
      {:reply, error(state, actor, "Invalid payload or editor actor."), state}
    end
  end

  def handle_call({:history, actor, direction}, from, state) do
    if authorized?(state, actor, from),
      do: history(state, actor, direction),
      else: {:reply, error(state, actor, "Editor actor is not bound to this process."), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case Enum.find(state.sessions, fn {_, session} -> session.monitor == ref end) do
      {actor, _} -> {:noreply, remove_actor(state, actor)}
      nil -> {:noreply, state}
    end
  end

  defp initial_interval(opts) do
    interval = Keyword.get(opts, :update_interval_ms, 500)
    if is_integer(interval) and interval in 25..2000, do: interval, else: 500
  end

  defp authorized?(state, actor, {pid, _}), do: match?(%{pid: ^pid}, state.sessions[actor])

  defp drop_session(state, actor) do
    case state.sessions[actor] do
      nil ->
        state

      session ->
        Process.demonitor(session.monitor, [:flush])
        %{state | sessions: Map.delete(state.sessions, actor)}
    end
  end

  defp remove_actor(state, actor) do
    state = drop_session(state, actor)
    broadcast_presence(state, actor, nil)

    %{
      state
      | presence: Map.delete(state.presence, actor),
        history: Map.delete(state.history, actor)
    }
  end

  defp update_presence(state, actor, params) do
    draft = params["draft"]

    valid =
      is_nil(draft) or
        (is_map(draft) and byte_size(:erlang.term_to_binary(draft)) <= 131_072 and
           valid_draft?(draft))

    cursor = params["cursor"]

    cursor =
      case cursor do
        %{"lng" => x, "lat" => y} -> [x, y]
        other -> other
      end

    if valid and (is_nil(cursor) or Reducer.coordinate?(cursor)) do
      params =
        Map.put(
          params,
          "cursor",
          if(cursor, do: %{lng: hd(cursor), lat: List.last(cursor)}, else: nil)
        )

      previous_draft = state.presence[actor]["draft"]

      params =
        if is_map(previous_draft) and is_map(draft) and previous_draft["id"] == draft["id"] and
             previous_draft["sequence"] >= draft["sequence"],
           do: Map.delete(params, "draft"),
           else: params

      entry =
        Map.merge(
          state.presence[actor],
          Map.take(params, ["draft", "cursor", "selected", "editing", "drawing_mode"])
        )

      changed = state.presence[actor] != entry
      state = %{state | presence: Map.put(state.presence, actor, entry)}
      if changed, do: broadcast_presence(state, actor, entry)
      {:reply, %{}, state}
    else
      {:reply, %{error: "Invalid cursor or drawing preview."}, state}
    end
  end

  defp valid_draft?(%{
         "id" => id,
         "sequence" => sequence,
         "mode" => mode,
         "feature" => %{"geometry" => geometry}
       })
       when is_binary(id) and byte_size(id) in 1..128 and is_integer(sequence) and sequence > 0 do
    mode in PhxMaplibre.Editor.Config.drawing_modes() and valid_preview_geometry?(geometry)
  end

  defp valid_draft?(_), do: false

  defp valid_preview_geometry?(%{"coordinates" => _} = geometry) do
    case geometry do
      %{"type" => "Point", "coordinates" => coordinate} ->
        Reducer.coordinate?(coordinate)

      %{"type" => "LineString", "coordinates" => coordinates} ->
        is_list(coordinates) and length(coordinates) <= 1000 and
          Enum.all?(coordinates, &Reducer.coordinate?/1)

      %{"type" => "Polygon", "coordinates" => [coordinates]} ->
        is_list(coordinates) and length(coordinates) <= 1001 and
          Enum.all?(coordinates, &Reducer.coordinate?/1)

      _ ->
        false
    end
  end

  defp valid_preview_geometry?(_), do: false

  defp update_settings(state, actor, params) do
    interval = params["update_interval_ms"]

    if is_integer(interval) and interval in 25..2000 do
      durable = put_in(state.durable, [:settings, :update_interval_ms], interval)
      commit(state, durable, actor)
    else
      {:reply, error(state, actor, "Choose an interval between 25 and 2000 ms."), state}
    end
  end

  defp mutation(state, actor, %{"action" => "finish"}), do: {:reply, reply(state, actor), state}

  defp mutation(state, actor, params) do
    durable = state.durable

    feature_id =
      case params["feature"] do
        %{} = feature -> feature["id"]
        _ -> nil
      end

    id = params["id"] || feature_id || Reducer.id()
    before = durable.features[id]
    sequence = params["sequence"]
    receipt = if is_integer(sequence), do: Jason.encode!([actor, id, sequence]), else: nil

    if receipt && Map.has_key?(durable.receipts, receipt) do
      {:reply, reply(state, actor), state}
    else
      result =
        case params["action"] do
          "create" ->
            cond do
              Map.has_key?(durable.features, id) or Map.has_key?(durable.deleted, id) ->
                {:error, "Feature ID already exists or was deleted."}

              map_size(durable.features) >= Keyword.get(state.opts, :max_features, 1000) ->
                {:error, "Document feature limit reached."}

              not is_map(params["mode_properties"] || %{}) ->
                {:error, "Invalid drawing mode properties."}

              not is_map(params["feature"]) ->
                {:error, "Invalid feature."}

              true ->
                with {:ok, entry} <-
                       Reducer.create(
                         Map.put(params["feature"], "id", id),
                         params["mode"] || "polygon",
                         params["vertex_ids"]
                       ) do
                  {:ok,
                   put_in(
                     entry.metadata["properties"],
                     Map.drop(
                       params["mode_properties"] || %{},
                       ~w(mode selected currentlyDrawing)
                     )
                   )}
                end
            end

          "delete" ->
            if before, do: {:ok, nil}, else: {:error, "Feature was deleted."}

          "properties" ->
            if before,
              do:
                Reducer.edit(before, [
                  %{"type" => "properties", "properties" => params["properties"]}
                ]),
              else: {:error, "Feature was deleted."}

          "edit" ->
            if not is_nil(before) and is_integer(sequence) and sequence > 0 do
              if sequence <= Map.get(before.metadata["acknowledgements"], actor, 0),
                do: {:ok, before},
                else: Reducer.edit(before, params["operations"])
            else
              {:error, "Invalid edit or deleted feature."}
            end

          _ ->
            {:error, "Unknown editor action."}
        end

      case result do
        {:error, reason} ->
          {:reply, error(state, actor, reason), state}

        {:ok, after_entry} ->
          if after_entry &&
               length(after_entry.metadata["vertex_ids"]) >
                 Keyword.get(state.opts, :max_vertices, 1000) do
            {:reply, error(state, actor, "Feature coordinate limit reached."), state}
          else
            after_entry =
              if after_entry && is_integer(sequence),
                do: put_in(after_entry.metadata["acknowledgements"][actor], sequence),
                else: after_entry

            features =
              if after_entry,
                do: Map.put(durable.features, id, after_entry),
                else: Map.delete(durable.features, id)

            durable = %{
              durable
              | features: features,
                deleted:
                  if(after_entry,
                    do: durable.deleted,
                    else: Map.put(durable.deleted, id, durable.revision + 1)
                  ),
                receipts:
                  if(receipt,
                    do: Map.put(durable.receipts, receipt, true),
                    else: durable.receipts
                  )
            }

            next_history =
              record(
                state.history,
                actor,
                id,
                before,
                after_entry,
                params["gesture_id"] || Reducer.id()
              )

            extras = if params["action"] == "create", do: %{created: id}, else: %{}
            commit(state, durable, actor, extras, next_history, params["action"] == "create")
          end
      end
    end
  end

  defp record(histories, actor, id, before, after_entry, gesture) do
    history = Map.get(histories, actor, %{undo: [], redo: []})
    patch = patch(before, after_entry)

    undo =
      case history.undo do
        [%{id: ^id, gesture: ^gesture} = previous | rest] ->
          [%{previous | patches: merge_patches(previous.patches, patch)} | rest]

        _ ->
          [%{id: id, gesture: gesture, patches: patch} | history.undo]
      end

    Map.put(histories, actor, %{undo: Enum.take(undo, 100), redo: []})
  end

  defp patch(nil, after_entry), do: [%{path: [], before: nil, after: after_entry}]
  defp patch(before, nil), do: [%{path: [], before: before, after: nil}]

  defp patch(before, after_entry) do
    paths =
      Enum.map(
        Enum.uniq(Map.keys(before.metadata["nodes"]) ++ Map.keys(after_entry.metadata["nodes"])),
        &[:metadata, "nodes", &1]
      ) ++
        Enum.map(
          Enum.uniq(
            Map.keys(before.feature["properties"]) ++ Map.keys(after_entry.feature["properties"])
          ),
          &[:feature, "properties", &1]
        )

    paths =
      paths ++
        Enum.map(
          Enum.uniq(
            Map.keys(before.metadata["property_versions"] || %{}) ++
              Map.keys(after_entry.metadata["property_versions"] || %{})
          ),
          &[:metadata, "property_versions", &1]
        )

    paths =
      paths ++
        Enum.map(
          Enum.uniq(
            Map.keys(before.metadata["properties"] || %{}) ++
              Map.keys(after_entry.metadata["properties"] || %{})
          ),
          &[:metadata, "properties", &1]
        ) ++
        Enum.map(
          Enum.uniq(
            Map.keys(before.metadata["mode_property_versions"] || %{}) ++
              Map.keys(after_entry.metadata["mode_property_versions"] || %{})
          ),
          &[:metadata, "mode_property_versions", &1]
        )

    paths =
      if before.feature["geometry"]["type"] != after_entry.feature["geometry"]["type"],
        do: paths ++ [[:feature, "geometry", "type"]],
        else: paths

    Enum.flat_map(paths, fn path ->
      old = get_in(before, path)
      new = get_in(after_entry, path)
      if old == new, do: [], else: [%{path: path, before: old, after: new}]
    end)
  end

  defp merge_patches(old, new) do
    Enum.reduce(new, old, fn patch, acc ->
      case Enum.find_index(acc, &(&1.path == patch.path)) do
        nil -> acc ++ [patch]
        index -> List.update_at(acc, index, &%{&1 | after: patch.after})
      end
    end)
  end

  defp history(state, actor, direction) do
    histories = Map.get(state.history, actor, %{undo: [], redo: []})
    reverse = if direction == :undo, do: :redo, else: :undo

    case histories[direction] do
      [] ->
        {:reply, error(state, actor, "No edit to #{direction}."), state}

      [item | rest] ->
        current = state.durable.features[item.id]
        expected_key = if direction == :undo, do: :after, else: :before
        value_key = if direction == :undo, do: :before, else: :after

        if Enum.all?(item.patches, fn patch ->
             if patch.path == [],
               do: comparable(current) == comparable(patch[expected_key]),
               else: current && get_in(current, patch.path) == patch[expected_key]
           end) do
          next =
            Enum.reduce(item.patches, current, fn patch, acc ->
              if patch.path == [],
                do: patch[value_key],
                else:
                  if(is_nil(patch[value_key]),
                    do: elem(pop_in(acc, patch.path), 1),
                    else: put_in(acc, patch.path, patch[value_key])
                  )
            end)

          next =
            if next && current do
              Enum.reduce(item.patches, next, fn patch, acc ->
                case patch.path do
                  [:metadata, "nodes", id] ->
                    if acc.metadata["nodes"][id],
                      do:
                        put_in(
                          acc.metadata["nodes"][id]["version"],
                          ((current.metadata["nodes"][id] || %{})["version"] || 0) + 1
                        ),
                      else: acc

                  [:metadata, "mode_property_versions", key] ->
                    put_in(
                      acc.metadata["mode_property_versions"][key],
                      (current.metadata["mode_property_versions"][key] || 0) + 1
                    )

                  [:metadata, "property_versions", key] ->
                    put_in(
                      acc.metadata["property_versions"][key],
                      (current.metadata["property_versions"][key] || 0) + 1
                    )

                  _ ->
                    acc
                end
              end)
            else
              next
            end

          next =
            if next,
              do: next |> Reducer.materialize() |> update_in([:metadata, "version"], &(&1 + 1)),
              else: nil

          # Node identities removed by undo remain as tombstones when later insertions depend on them.
          result =
            cond do
              next &&
                  Enum.any?(next.metadata["nodes"], fn {_, node} ->
                    node["after"] && not Map.has_key?(next.metadata["nodes"], node["after"])
                  end) ->
                {:error, :dependent_insert}

              next ->
                Reducer.validate(next.feature["geometry"])

              true ->
                :ok
            end

          if result == :ok and
               (is_nil(next) or
                  Enum.all?(next.metadata["nodes"], fn {_, node} ->
                    is_nil(node["after"]) or Map.has_key?(next.metadata["nodes"], node["after"])
                  end)) do
            durable = %{
              state.durable
              | deleted:
                  if(next,
                    do: state.durable.deleted,
                    else: Map.put(state.durable.deleted, item.id, state.durable.revision + 1)
                  ),
                features:
                  if(next,
                    do: Map.put(state.durable.features, item.id, next),
                    else: Map.delete(state.durable.features, item.id)
                  )
            }

            item = %{
              item
              | patches:
                  Enum.map(item.patches, fn patch ->
                    Map.put(
                      patch,
                      value_key,
                      if(patch.path == [], do: next, else: next && get_in(next, patch.path))
                    )
                  end)
            }

            updated =
              histories
              |> Map.put(direction, rest)
              |> Map.put(reverse, [item | histories[reverse]])

            commit(state, durable, actor, %{}, Map.put(state.history, actor, updated))
          else
            {:reply, error(state, actor, "Undo/redo would invalidate geometry."), state}
          end
        else
          {:reply, error(state, actor, "Undo/redo conflicts with another visitor's edits."),
           state}
        end
    end
  end

  defp commit(state, durable, actor, extras \\ %{}, history \\ nil, clear_draft \\ false) do
    next = %{durable | revision: state.durable.revision + 1}

    persisted =
      case state.storage do
        nil ->
          :ok

        {module, opts} ->
          module.commit(
            next.document_id,
            {state.durable.generation, state.durable.revision},
            next,
            opts
          )
      end

    case persisted do
      :ok ->
        state = %{state | durable: next, history: history || state.history}

        state =
          if clear_draft,
            do: %{
              state
              | presence: Map.update!(state.presence, actor, &Map.put(&1, "draft", nil))
            },
            else: state

        broadcast(state, :snapshot, Map.delete(public(state), :presence))
        if clear_draft, do: broadcast_presence(state, actor, state.presence[actor])
        {:reply, Map.merge(reply(state, actor), extras), state}

      {:error, reason} ->
        state =
          case state.storage do
            {module, opts} ->
              case module.load(state.durable.document_id, opts) do
                {:ok, loaded} when is_map(loaded) ->
                  %{state | durable: normalize(loaded), history: %{}}

                _ ->
                  state
              end

            nil ->
              state
          end

        {:reply, error(state, actor, "Persistence rejected edit: #{inspect(reason)}"), state}
    end
  end

  defp comparable(nil), do: nil

  defp comparable(entry),
    do: %{entry | metadata: Map.drop(entry.metadata, ["version", "acknowledgements"])}

  defp normalize(%{"document_id" => _} = state) do
    %{
      document_id: state["document_id"],
      generation: state["generation"],
      revision: state["revision"],
      features:
        Map.new(state["features"], fn {id, entry} ->
          {id, %{feature: entry["feature"], metadata: entry["metadata"]}}
        end),
      deleted: state["deleted"],
      receipts: state["receipts"],
      settings: %{update_interval_ms: state["settings"]["update_interval_ms"]}
    }
  end

  defp normalize(state), do: state

  defp public(state) do
    durable = state.durable

    %{
      document_id: durable.document_id,
      generation: durable.generation,
      revision: durable.revision,
      features:
        durable.features |> Map.values() |> Enum.map(& &1.feature) |> Enum.sort_by(& &1["id"]),
      metadata: Map.new(durable.features, fn {id, entry} -> {id, entry.metadata} end),
      settings: durable.settings,
      presence: %{entries: Map.values(state.presence)}
    }
  end

  defp reply(state, actor) do
    history = Map.get(state.history, actor, %{undo: [], redo: []})

    Map.put(public(state), :history, %{
      undo_size: length(history.undo),
      redo_size: length(history.redo)
    })
  end

  defp error(state, actor, message), do: Map.put(reply(state, actor), :error, message)

  defp broadcast_presence(state, actor, entry),
    do: broadcast(state, :presence, %{actor_id: actor, entry: entry})

  defp broadcast(%{pubsub: nil}, _, _), do: :ok

  defp broadcast(state, kind, payload),
    do:
      Phoenix.PubSub.broadcast(
        state.pubsub,
        Runtime.topic(state.durable.document_id),
        {:phx_maplibre_editor, state.durable.document_id, kind, payload}
      )
end
