defmodule PhxMaplibre.Editor.Runtime do
  @moduledoc "Explicitly started, lazy shared-editor runtime. Ordinary maps never start this process."
  use GenServer
  alias PhxMaplibre.Editor.Document
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def resolve(runtime, document_id, initial_opts \\ []),
    do: GenServer.call(runtime, {:resolve, document_id, initial_opts})

  def pubsub(runtime), do: GenServer.call(runtime, :pubsub)
  def topic(document_id), do: "phx_maplibre:editor:" <> document_id
  @impl true
  def init(opts), do: {:ok, %{opts: opts, documents: %{}, monitors: %{}}}
  @impl true
  def handle_call(:pubsub, _, state), do: {:reply, Keyword.get(state.opts, :pubsub), state}

  def handle_call({:resolve, id, initial_opts}, _from, state)
      when is_binary(id) and byte_size(id) in 1..256 do
    case Keyword.get(state.opts, :owner) do
      {module, opts} ->
        {:reply, module.resolve(id, opts), state}

      nil ->
        case Map.fetch(state.documents, id) do
          {:ok, pid} ->
            if Process.alive?(pid),
              do: {:reply, {:ok, pid}, state},
              else:
                handle_call({:resolve, id, initial_opts}, nil, %{
                  state
                  | documents: Map.delete(state.documents, id)
                })

          :error ->
            case Document.start(
                   state.opts
                   |> Keyword.merge(Keyword.take(initial_opts, [:update_interval_ms]))
                   |> Keyword.put(:document_id, id)
                 ) do
              {:ok, pid} ->
                ref = Process.monitor(pid)

                {:reply, {:ok, pid},
                 %{
                   state
                   | documents: Map.put(state.documents, id, pid),
                     monitors: Map.put(state.monitors, ref, id)
                 }}

              error ->
                {:reply, error, state}
            end
        end
    end
  end

  def handle_call({:resolve, _, _}, _from, state),
    do: {:reply, {:error, :invalid_document_id}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    {id, monitors} = Map.pop(state.monitors, ref)

    documents =
      if state.documents[id] == pid, do: Map.delete(state.documents, id), else: state.documents

    {:noreply, %{state | monitors: monitors, documents: documents}}
  end

  @impl true
  def terminate(_, state),
    do:
      Enum.each(state.documents, fn {_, pid} ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)
end
