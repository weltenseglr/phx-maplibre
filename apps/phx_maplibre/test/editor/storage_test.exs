defmodule PhxMaplibre.Editor.StorageTest do
  use ExUnit.Case, async: true
  alias PhxMaplibre.Editor.{Document, Runtime}

  defmodule Storage do
    @behaviour PhxMaplibre.Editor.Storage
    def load(id, agent), do: {:ok, Agent.get(agent, &Map.get(&1, id))}

    def commit(id, expected, state, agent) do
      Agent.get_and_update(agent, fn documents ->
        existing = documents[id]

        cond do
          documents[:fail] ->
            {{:error, :unavailable}, documents}

          existing && {existing.generation, existing.revision} != expected ->
            {{:error, :stale_owner}, documents}

          true ->
            {:ok, Map.put(documents, id, state)}
        end
      end)
    end
  end

  defp create(doc),
    do:
      Document.mutate(doc, "a", %{
        "action" => "create",
        "mode" => "point",
        "feature" => %{
          "type" => "Feature",
          "id" => "p",
          "properties" => %{},
          "geometry" => %{"type" => "Point", "coordinates" => [1, 2]}
        }
      })

  test "commit errors do not acknowledge; durable state survives owner restart" do
    store = start_supervised!({Agent, fn -> %{} end})
    runtime = start_supervised!({Runtime, [storage: {Storage, store}]})
    {:ok, doc} = Runtime.resolve(runtime, "doc")
    Document.join(doc, "a", %{})
    Agent.update(store, &Map.put(&1, :fail, true))
    assert create(doc).error =~ "Persistence"
    assert Document.snapshot(doc).revision == 0
    Agent.update(store, &Map.delete(&1, :fail))
    saved = create(doc)
    GenServer.stop(doc)
    {:ok, restored} = Runtime.resolve(runtime, "doc")
    assert Document.snapshot(restored).generation == saved.generation
    assert Document.snapshot(restored).features == saved.features
  end

  test "stale owner reloads authoritative state" do
    store = start_supervised!({Agent, fn -> %{} end})
    {:ok, first} = Document.start_link(document_id: "doc", storage: {Storage, store})
    Document.join(first, "a", %{})
    create(first)
    {:ok, stale} = Document.start_link(document_id: "doc", storage: {Storage, store})
    Document.join(stale, "a", %{})

    Document.mutate(first, "a", %{
      "action" => "properties",
      "id" => "p",
      "properties" => %{"name" => "latest"}
    })

    result = Document.mutate(stale, "a", %{"action" => "delete", "id" => "p"})
    assert result.error =~ "stale_owner"
    assert hd(result.features)["properties"]["name"] == "latest"
    assert result.revision == 2
  end

  test "enabled upstream geometry modes preserve metadata" do
    for {type, coordinates, modes} <- [
          {"Point", [1, 2], ~w(point marker text)},
          {"LineString", [[0, 0], [1, 1]], ~w(linestring line polyline freehand-linestring)},
          {"Polygon", [[[0, 0], [2, 0], [0, 2], [0, 0]]],
           ~w(polygon rectangle angled-rectangle circle freehand sensor sector)}
        ],
        mode <- modes do
      assert {:ok, entry} =
               PhxMaplibre.Editor.Reducer.create(
                 %{
                   "type" => "Feature",
                   "id" => "f",
                   "geometry" => %{"type" => type, "coordinates" => coordinates}
                 },
                 mode
               )

      assert entry.metadata["mode"] == mode
      assert entry.feature["geometry"]["type"] == type
    end

    assert {:error, _} =
             PhxMaplibre.Editor.Reducer.create(
               %{
                 "type" => "Feature",
                 "geometry" => %{"type" => "Point", "coordinates" => [0, 0]}
               },
               "polygon"
             )
  end

  defmodule Owner do
    @behaviour PhxMaplibre.Editor.Owner
    def resolve(id, opts) do
      send(opts[:test_pid], {:resolved, id})
      {:ok, opts[:document]}
    end
  end

  test "external owner resolver routes document calls" do
    {:ok, doc} = Document.start_link(document_id: "external")
    runtime = start_supervised!({Runtime, [owner: {Owner, [test_pid: self(), document: doc]}]})
    assert Runtime.resolve(runtime, "external") == {:ok, doc}
    assert_receive {:resolved, "external"}
  end

  test "failed durable commit publishes no snapshot" do
    pubsub = Module.concat(__MODULE__, "PubSub#{System.unique_integer([:positive])}")
    start_supervised!({Phoenix.PubSub, name: pubsub})
    Phoenix.PubSub.subscribe(pubsub, Runtime.topic("doc"))
    store = start_supervised!({Agent, fn -> %{fail: true} end})

    {:ok, doc} =
      Document.start_link(document_id: "doc", storage: {Storage, store}, pubsub: pubsub)

    Document.join(doc, "a", %{})
    assert_receive {:phx_maplibre_editor, "doc", :presence, _}
    assert create(doc).error
    refute_receive {:phx_maplibre_editor, "doc", :snapshot, _}
  end

  test "JSONB adapter roundtrip restores known structural keys" do
    store = start_supervised!({Agent, fn -> %{} end})
    {:ok, doc} = Document.start_link(document_id: "doc", storage: {Storage, store})
    Document.join(doc, "a", %{})
    create(doc)
    state = Agent.get(store, & &1["doc"]) |> Jason.encode!() |> Jason.decode!()
    Agent.update(store, &Map.put(&1, "doc", state))
    {:ok, loaded} = Document.start_link(document_id: "doc", storage: {Storage, store})
    assert hd(Document.snapshot(loaded).features)["id"] == "p"
    assert Document.snapshot(loaded).settings.update_interval_ms == 500
  end
end
