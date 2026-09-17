defmodule PhxMaplibre.Editor.DocumentTest do
  use ExUnit.Case, async: true
  alias PhxMaplibre.Editor.{Document, Runtime}

  setup do
    runtime = start_supervised!({Runtime, []})
    {:ok, doc} = Runtime.resolve(runtime, "one")
    Document.join(doc, "a", %{name: "A"})
    %{doc: doc, runtime: runtime}
  end

  defp create(doc, id \\ "f") do
    Document.mutate(doc, "a", %{
      "action" => "create",
      "mode" => "polygon",
      "vertex_ids" => ["a", "b", "c"],
      "feature" => %{
        "type" => "Feature",
        "id" => id,
        "properties" => %{"name" => "original"},
        "geometry" => %{"type" => "Polygon", "coordinates" => [[[0, 0], [4, 0], [0, 4], [0, 0]]]}
      }
    })
  end

  defp edit(doc, seq, ops, gesture \\ "gesture"),
    do:
      Document.mutate(doc, "a", %{
        "action" => "edit",
        "id" => "f",
        "sequence" => seq,
        "operations" => ops,
        "gesture_id" => gesture
      })

  test "documents isolate state and metadata stays outside GeoJSON", %{doc: doc, runtime: runtime} do
    result = create(doc)
    assert result.created == "f"
    assert result.metadata["f"]["vertex_ids"] == ["a", "b", "c"]
    refute Map.has_key?(hd(result.features)["properties"], "vertex_ids")
    {:ok, other} = Runtime.resolve(runtime, "two")
    assert Document.snapshot(other).features == []
  end

  test "independent edits merge; retry is idempotent; removed anchors survive", %{doc: doc} do
    create(doc)
    edit(doc, 1, [%{"type" => "move", "vertex_id" => "a", "coordinate" => [1, 1]}])
    result = edit(doc, 2, [%{"type" => "move", "vertex_id" => "b", "coordinate" => [5, 0]}])
    assert hd(result.features)["geometry"]["coordinates"] == [[[1, 1], [5, 0], [0, 4], [1, 1]]]

    assert edit(doc, 2, [%{"type" => "move", "vertex_id" => "a", "coordinate" => [9, 9]}]).revision ==
             result.revision

    result =
      edit(doc, 3, [
        %{"type" => "insert", "vertex_id" => "d", "after_id" => "b", "coordinate" => [2, 2]},
        %{"type" => "remove", "vertex_id" => "b"}
      ])

    assert result.metadata["f"]["nodes"]["b"]["deleted"]
    assert result.metadata["f"]["vertex_ids"] == ["a", "d", "c"]
  end

  test "gesture undo and redo preserve unrelated remote fields", %{doc: doc} do
    create(doc)
    edit(doc, 1, [%{"type" => "move", "vertex_id" => "a", "coordinate" => [1, 1]}])
    edit(doc, 2, [%{"type" => "move", "vertex_id" => "a", "coordinate" => [2, 1]}])
    Document.join(doc, "b", %{})

    Document.mutate(doc, "b", %{
      "action" => "properties",
      "id" => "f",
      "properties" => %{"name" => "remote"}
    })

    result = Document.undo(doc, "a")
    refute result[:error]
    assert result.metadata["f"]["nodes"]["a"]["coordinate"] == [0, 0]
    assert hd(result.features)["properties"]["name"] == "remote"
    assert Document.redo(doc, "a").metadata["f"]["nodes"]["a"]["coordinate"] == [2, 1]
  end

  test "same-coordinate remote edit rejects undo", %{doc: doc} do
    create(doc)
    edit(doc, 1, [%{"type" => "move", "vertex_id" => "a", "coordinate" => [1, 1]}])
    Document.join(doc, "b", %{})

    Document.mutate(doc, "b", %{
      "action" => "edit",
      "id" => "f",
      "sequence" => 1,
      "operations" => [%{"type" => "move", "vertex_id" => "a", "coordinate" => [2, 1]}]
    })

    assert Document.undo(doc, "a").error =~ "conflicts"
  end

  test "actor binding forbids another process and malformed draft is rejected", %{doc: doc} do
    assert Task.async(fn -> Document.mutate(doc, "a", %{"action" => "delete", "id" => "f"}) end)
           |> Task.await()
           |> Map.has_key?(:error)

    assert Document.presence(doc, "a", %{
             "draft" => %{"geometry" => %{"type" => "LineString", "coordinates" => [nil]}}
           }).error
  end

  test "creation clears preview and deletion cannot resurrect through stale edit", %{doc: doc} do
    Document.presence(doc, "a", %{
      "draft" => %{"geometry" => %{"type" => "LineString", "coordinates" => [[1, 1]]}}
    })

    result = create(doc)
    assert hd(result.presence.entries)["draft"] == nil
    Document.mutate(doc, "a", %{"action" => "delete", "id" => "f"})
    assert edit(doc, 1, []).error
    assert create(doc).error
    result = Document.undo(doc, "a")
    refute result[:error]
    assert length(result.features) == 1
    assert Document.redo(doc, "a").features == []
  end

  test "property ABA conflicts with undo even when value returns", %{doc: doc} do
    create(doc)

    Document.mutate(doc, "a", %{
      "action" => "properties",
      "id" => "f",
      "properties" => %{"name" => "mine"}
    })

    Document.join(doc, "b", %{})

    for name <- ["other", "mine"] do
      Document.mutate(doc, "b", %{
        "action" => "properties",
        "id" => "f",
        "properties" => %{"name" => name}
      })
    end

    assert Document.undo(doc, "a").error =~ "conflicts"
  end

  test "deterministic insertion ordering and translation deltas", %{doc: doc} do
    create(doc)

    edit(doc, 1, [
      %{"type" => "insert", "vertex_id" => "z", "after_id" => "a", "coordinate" => [2, 0]}
    ])

    result =
      edit(doc, 2, [
        %{"type" => "insert", "vertex_id" => "d", "after_id" => "a", "coordinate" => [1, 0]}
      ])

    assert result.metadata["f"]["vertex_ids"] == ["a", "d", "z", "b", "c"]
    result = edit(doc, 3, [%{"type" => "translate", "delta" => [1, 2]}])
    assert result.metadata["f"]["nodes"]["a"]["coordinate"] == [1, 2]
    assert result.metadata["f"]["nodes"]["b"]["coordinate"] == [5, 2]
  end

  test "topology replacement is version guarded and preserves mode metadata", %{doc: doc} do
    result = create(doc)
    old_version = result.metadata["f"]["version"]
    edit(doc, 1, [%{"type" => "move", "vertex_id" => "a", "coordinate" => [1, 1]}])

    operation = %{
      "type" => "replace_geometry",
      "expected_version" => old_version,
      "geometry" => %{"type" => "Polygon", "coordinates" => [[[0, 0], [3, 0], [0, 3], [0, 0]]]}
    }

    assert edit(doc, 2, [operation]).error =~ "concurrently"
    result = edit(doc, 3, [Map.put(operation, "expected_version", 1)])
    refute result[:error]
    assert result.metadata["f"]["mode"] == "polygon"
    assert result.metadata["f"]["acknowledgements"]["a"] == 3
  end

  test "history bounded to100 and repeated join does not reset", %{doc: doc} do
    create(doc)

    for index <- 1..105 do
      Document.mutate(doc, "a", %{
        "action" => "properties",
        "id" => "f",
        "properties" => %{"name" => "Name #{index}"}
      })
    end

    assert Document.join(doc, "a", %{}).history.undo_size == 100
    Document.leave(doc, "a")
    assert Document.join(doc, "a", %{}).history.undo_size == 0
  end

  test "undo create and redo remain reversible", %{doc: doc} do
    create(doc)
    assert Document.undo(doc, "a").features == []
    assert length(Document.redo(doc, "a").features) == 1
    assert Document.undo(doc, "a").features == []
  end

  test "shared browser/server operation fixtures" do
    fixtures = __DIR__ |> Path.join("protocol.json") |> File.read!() |> Jason.decode!()

    for fixture <- fixtures do
      assert {:ok, entry} =
               PhxMaplibre.Editor.Reducer.create(
                 %{"type" => "Feature", "id" => "fixture", "geometry" => fixture["geometry"]},
                 fixture["mode"],
                 fixture["vertex_ids"]
               )

      assert {:ok, result} = PhxMaplibre.Editor.Reducer.edit(entry, fixture["operations"])

      assert result.feature["geometry"]["coordinates"] == fixture["expected_coordinates"],
             fixture["name"]

      assert result.metadata["vertex_ids"] == fixture["expected_vertex_ids"], fixture["name"]
    end
  end

  test "initial interval is configuration for new documents only", %{runtime: runtime} do
    {:ok, configured} = Runtime.resolve(runtime, "configured", update_interval_ms: 250)
    assert Document.snapshot(configured).settings.update_interval_ms == 250
    assert Runtime.resolve(runtime, "configured", update_interval_ms: 1000) == {:ok, configured}
    assert Document.snapshot(configured).settings.update_interval_ms == 250
  end

  test "text metadata edits support guarded undo and redo", %{doc: doc} do
    Document.mutate(doc, "a", %{
      "action" => "create",
      "mode" => "text",
      "mode_properties" => %{"text" => "original"},
      "feature" => %{
        "type" => "Feature",
        "id" => "text",
        "geometry" => %{"type" => "Point", "coordinates" => [1, 2]},
        "properties" => %{}
      }
    })

    params = %{
      "action" => "edit",
      "id" => "text",
      "sequence" => 1,
      "operations" => [
        %{
          "type" => "mode_properties",
          "expected_version" => 0,
          "properties" => %{"text" => "changed"}
        }
      ]
    }

    result = Document.mutate(doc, "a", params)
    assert result.metadata["text"]["properties"]["text"] == "changed"
    refute hd(result.features)["properties"]["text"]
    assert Document.undo(doc, "a").metadata["text"]["properties"]["text"] == "original"
    assert Document.redo(doc, "a").metadata["text"]["properties"]["text"] == "changed"
    # Pure label writes follow arrival order and merge with coordinate movement.
    Document.join(doc, "b", %{})

    remote =
      Document.mutate(doc, "b", %{
        "action" => "edit",
        "id" => "text",
        "sequence" => 1,
        "operations" => [%{"type" => "translate", "delta" => [1, 2]}]
      })

    refute remote[:error]
    next = Document.mutate(doc, "a", Map.put(params, "sequence", 2))
    refute next[:error]
    assert hd(next.features)["geometry"]["coordinates"] == [2, 4]
  end

  test "out of order draft checkpoints cannot rewind preview", %{doc: doc} do
    draft = %{
      "id" => "draft",
      "sequence" => 2,
      "mode" => "polygon",
      "feature" => %{"geometry" => %{"type" => "Polygon", "coordinates" => [[[0, 0], [1, 1]]]}}
    }

    assert Document.presence(doc, "a", %{"draft" => draft}) == %{}
    assert Document.presence(doc, "a", %{"draft" => Map.put(draft, "sequence", 1)}) == %{}
    assert hd(Document.snapshot(doc).presence.entries)["draft"]["sequence"] == 2
  end

  test "malformed feature containers reject without restarting the document", %{doc: doc} do
    before = Document.snapshot(doc)

    for feature <- ["invalid", [], 42, false, nil] do
      assert Document.mutate(doc, "a", %{
               "action" => "create",
               "mode" => "point",
               "feature" => feature
             }).error

      assert Document.snapshot(doc).generation == before.generation
      assert Document.snapshot(doc).revision == before.revision
    end
  end
end
