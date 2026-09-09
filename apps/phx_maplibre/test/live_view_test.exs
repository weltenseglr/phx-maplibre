defmodule PhxMaplibre.LiveViewTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhxMaplibre.{Command, Event}

  @endpoint PhxMaplibre.TestSupport.Endpoint
  @pubsub PhxMaplibre.TestPubSub

  setup do
    conn = Plug.Test.init_test_session(build_conn(), %{})
    {:ok, view, _html} = live_isolated(conn, PhxMaplibre.TestSupport.TestLive)
    %{view: view}
  end

  test "client events are broadcast as %Event{} on the events topic", %{view: view} do
    :ok = PhxMaplibre.subscribe("test-map", pubsub: @pubsub)

    render_hook(view, "maplibre:event", %{
      "id" => "test-map",
      "event" => "move_end",
      "payload" => %{
        "bounds" => %{"west" => 1.0, "south" => 2.0, "east" => 3.0, "north" => 4.0},
        "center" => %{"lng" => 2.0, "lat" => 3.0},
        "zoom" => 11
      }
    })

    assert_receive %Event{map_id: "test-map", event: :move_end, payload: payload, meta: meta}
    assert payload.bounds == %{west: 1.0, south: 2.0, east: 3.0, north: 4.0}
    assert payload.zoom == 11
    assert meta.pid == view.pid
  end

  test "feature properties keep their string keys", %{view: view} do
    :ok = PhxMaplibre.subscribe("test-map", pubsub: @pubsub)

    render_hook(view, "maplibre:event", %{
      "id" => "test-map",
      "event" => "feature_selected",
      "payload" => %{
        "id" => "gsd-1",
        "kind" => "point",
        "lng" => 13.4,
        "lat" => 52.5,
        "feature" => %{
          "type" => "Feature",
          "id" => "gsd-1",
          "geometry" => %{"type" => "Point", "coordinates" => [13.4, 52.5]},
          "properties" => %{"title" => "GSD 1", "custom" => 42}
        }
      }
    })

    assert_receive %Event{event: :feature_selected, payload: payload}
    assert payload.id == "gsd-1"
    assert payload.feature["properties"] == %{"title" => "GSD 1", "custom" => 42}
    assert payload.feature["geometry"]["type"] == "Point"
  end

  test "unknown client event names are rejected without crashing", %{view: view} do
    :ok = PhxMaplibre.subscribe("test-map", pubsub: @pubsub)

    render_hook(view, "maplibre:event", %{
      "id" => "test-map",
      "event" => "bogus_event",
      "payload" => %{}
    })

    refute_receive %Event{}, 100
    assert render(view)
  end

  test "malformed client event params do not crash the LiveView", %{view: view} do
    :ok = PhxMaplibre.subscribe("test-map", pubsub: @pubsub)

    render_hook(view, "maplibre:event", %{"id" => "test-map", "event" => 1, "payload" => %{}})
    render_hook(view, "maplibre:event", %{"id" => "test-map", "event" => "ready", "payload" => "x"})
    render_hook(view, "maplibre:event", %{"id" => 42, "event" => "ready", "payload" => %{}})

    refute_receive %Event{}, 100
    assert render(view)
  end

  test "events for unattached maps are dropped", %{view: view} do
    :ok = PhxMaplibre.subscribe("other-map", pubsub: @pubsub)

    render_hook(view, "maplibre:event", %{
      "id" => "other-map",
      "event" => "ready",
      "payload" => %{}
    })

    refute_receive %Event{}, 100
    assert render(view)
  end

  test "commands broadcast over PubSub are pushed to the hook", %{view: view} do
    :ok = PhxMaplibre.fly_to("test-map", %{lng: 1.0, lat: 2.0}, pubsub: @pubsub)

    assert_push_event(view, "maplibre:test-map:fly_to", %{
      center: %{lng: 1.0, lat: 2.0},
      zoom: 14,
      duration: 1500
    })
  end

  test "command options override defaults", %{view: view} do
    :ok = PhxMaplibre.fly_to("test-map", %{lng: 1.0, lat: 2.0}, zoom: 8, pubsub: @pubsub)
    assert_push_event(view, "maplibre:test-map:fly_to", %{zoom: 8})
  end

  test "commands for unregistered maps are ignored without crashing", %{view: view} do
    command =
      Command.new!("ghost-map", :fly_to, %{center: %{lng: 1.0, lat: 2.0}, zoom: 14, duration: 1500})

    send(view.pid, command)
    assert render(view)
  end

  test "socket fast path pushes without PubSub traffic", %{view: view} do
    Phoenix.PubSub.subscribe(@pubsub, PhxMaplibre.commands_topic("test-map"))

    feature = %{type: "Feature", geometry: %{type: "Point", coordinates: [1.0, 2.0]}}
    send(view.pid, {:run_fast_path, [feature]})

    assert_push_event(view, "maplibre:test-map:set_features", %{
      geojson: %{type: "FeatureCollection", features: [_]}
    })

    refute_receive %Command{}, 100
  end

  test "broadcast set_features wraps feature lists into a FeatureCollection", %{view: view} do
    feature = %{type: "Feature", geometry: %{type: "Point", coordinates: [1.0, 2.0]}}
    :ok = PhxMaplibre.set_features("test-map", [feature], pubsub: @pubsub)

    assert_push_event(view, "maplibre:test-map:set_features", %{
      geojson: %{type: "FeatureCollection", features: [_]}
    })
  end

  describe "geojson is validated at the sender" do
    test "the PubSub form accepts a FeatureCollection or a list of Features", %{view: view} do
      feature = %{type: "Feature", geometry: %{type: "Point", coordinates: [1.0, 2.0]}}

      assert :ok = PhxMaplibre.set_features("test-map", [feature], pubsub: @pubsub)
      assert_push_event(view, "maplibre:test-map:set_features", %{geojson: _})

      assert :ok =
               PhxMaplibre.set_area_features(
                 "test-map",
                 %{"type" => "FeatureCollection", "features" => []},
                 pubsub: @pubsub
               )

      assert_push_event(view, "maplibre:test-map:set_area_features", %{geojson: _})
    end

    test "the PubSub form returns an error and broadcasts nothing", %{view: view} do
      for geojson <- [%{}, %{"type" => "Feature"}, [%{"type" => "Point"}], "nope"] do
        assert {:error, :invalid_geojson} =
                 PhxMaplibre.set_features("test-map", geojson, pubsub: @pubsub)

        assert {:error, :invalid_geojson} =
                 PhxMaplibre.set_area_features("test-map", geojson, pubsub: @pubsub)
      end

      assert_raise ExUnit.AssertionError, fn ->
        assert_push_event(view, "maplibre:test-map:set_features", %{geojson: _}, 100)
      end
    end

    test "the socket fast path raises instead" do
      socket = %Phoenix.LiveView.Socket{}

      assert_raise ArgumentError, ~r/geojson must be a FeatureCollection/, fn ->
        PhxMaplibre.set_features(socket, "test-map", %{})
      end

      assert_raise ArgumentError, ~r/geojson must be a FeatureCollection/, fn ->
        PhxMaplibre.set_area_features(socket, "test-map", [%{"type" => "Point"}])
      end
    end
  end

  describe "server-side event allowlist" do
    test "an event outside the map's :events list is dropped", %{view: view} do
      :ok = PhxMaplibre.subscribe("test-map", pubsub: @pubsub)

      send(view.pid, {:attach, "test-map", [pubsub: @pubsub, events: [:ready]]})
      _ = render(view)

      render_hook(view, "maplibre:event", %{
        "id" => "test-map",
        "event" => "feature_selected",
        "payload" => %{"id" => "f1"}
      })

      refute_receive %Event{}, 100

      # The one event that is allowed still gets through.
      render_hook(view, "maplibre:event", %{
        "id" => "test-map",
        "event" => "ready",
        "payload" => ready_payload()
      })

      assert_receive %Event{event: :ready}
    end

    test "hover events are not allowed by default", %{view: view} do
      :ok = PhxMaplibre.subscribe("test-map", pubsub: @pubsub)

      render_hook(view, "maplibre:event", %{
        "id" => "test-map",
        "event" => "feature_hovered",
        "payload" => %{"id" => "f1", "kind" => "point", "title" => "Pigeon"}
      })

      refute_receive %Event{}, 100
    end

    test ":events must be a list of atoms" do
      assert_raise ArgumentError, ~r/:events must be a list of atoms/, fn ->
        PhxMaplibre.LiveView.attach_map(%Phoenix.LiveView.Socket{}, "m1",
          pubsub: @pubsub,
          events: ["ready"]
        )
      end
    end
  end

  describe "client payload limits" do
    test "an oversized payload is dropped", %{view: view} do
      :ok = PhxMaplibre.subscribe("test-map", pubsub: @pubsub)

      render_hook(view, "maplibre:event", %{
        "id" => "test-map",
        "event" => "feature_selected",
        "payload" => selected_payload("f1", %{"blob" => String.duplicate("x", 600_000)})
      })

      refute_receive %Event{}, 100
      assert render(view)
    end

    test ":max_event_payload_bytes :infinity lets a large payload through", %{view: view} do
      :ok = PhxMaplibre.subscribe("test-map", pubsub: @pubsub)

      send(view.pid, {:attach, "test-map", [pubsub: @pubsub, max_event_payload_bytes: :infinity]})
      _ = render(view)

      render_hook(view, "maplibre:event", %{
        "id" => "test-map",
        "event" => "feature_selected",
        "payload" => selected_payload("f1", %{"blob" => String.duplicate("x", 600_000)})
      })

      assert_receive %Event{event: :feature_selected}, 500
    end

    test "a custom :max_event_payload_bytes limit is enforced", %{view: view} do
      :ok = PhxMaplibre.subscribe("test-map", pubsub: @pubsub)

      send(view.pid, {:attach, "test-map", [pubsub: @pubsub, max_event_payload_bytes: 64]})
      _ = render(view)

      render_hook(view, "maplibre:event", %{
        "id" => "test-map",
        "event" => "feature_selected",
        "payload" => %{"id" => "f1", "blob" => String.duplicate("x", 200)}
      })

      refute_receive %Event{}, 100
    end

    test "an invalid :max_event_payload_bytes raises at attach time" do
      assert_raise ArgumentError, ~r/max_event_payload_bytes/, fn ->
        PhxMaplibre.LiveView.attach_map(
          %Phoenix.LiveView.Socket{},
          "m",
          pubsub: @pubsub,
          max_event_payload_bytes: -1
        )
      end
    end

    test "a deeply nested unknown payload is relayed without blowing up", %{view: view} do
      :ok = PhxMaplibre.subscribe("test-map", pubsub: @pubsub)

      deep = Enum.reduce(1..200, %{"lng" => 1.0}, fn _, acc -> %{"center" => acc} end)

      render_hook(view, "maplibre:event", %{
        "id" => "test-map",
        "event" => "move_end",
        "payload" => %{
          "bounds" => %{"west" => 1, "south" => 2, "east" => 3, "north" => 4},
          "center" => %{"lng" => 2, "lat" => 3},
          "zoom" => 9,
          "extra" => deep
        }
      })

      assert_receive %Event{event: :move_end, payload: payload}
      assert payload.zoom == 9
      assert %{"center" => %{"center" => %{"center" => _}}} = payload["extra"]
    end
  end

  describe "detach and re-attach" do
    test "re-attaching with the same options does not duplicate command delivery", %{view: view} do
      send(view.pid, {:attach, "test-map", [pubsub: @pubsub]})
      # Synchronize so the re-attach has been processed before broadcasting.
      _ = render(view)

      :ok = PhxMaplibre.fly_to("test-map", %{lng: 1.0, lat: 2.0}, pubsub: @pubsub)

      assert_push_event(view, "maplibre:test-map:fly_to", %{center: _})

      # A leaked duplicate subscription would deliver the command twice.
      assert_raise ExUnit.AssertionError, fn ->
        assert_push_event(view, "maplibre:test-map:fly_to", %{center: _}, 150)
      end
    end

    test "detach_map stops command handling and event relaying", %{view: view} do
      :ok = PhxMaplibre.subscribe("test-map", pubsub: @pubsub)

      send(view.pid, {:detach, "test-map"})
      _ = render(view)

      :ok = PhxMaplibre.fly_to("test-map", %{lng: 1.0, lat: 2.0}, pubsub: @pubsub)

      assert_raise ExUnit.AssertionError, fn ->
        assert_push_event(view, "maplibre:test-map:fly_to", %{center: _}, 150)
      end

      render_hook(view, "maplibre:event", %{
        "id" => "test-map",
        "event" => "ready",
        "payload" => %{}
      })

      refute_receive %Event{}, 100
    end

    test "re-attaching with commands: false stops command delivery", %{view: view} do
      send(view.pid, {:attach, "test-map", [pubsub: @pubsub, commands: false]})
      _ = render(view)

      # Handed straight to the process, so this fails on the registry entry
      # alone — no subscription is involved in delivering it.
      send(
        view.pid,
        Command.new!("test-map", :fly_to, %{
          center: %{lng: 1.0, lat: 2.0},
          zoom: 14,
          duration: 1500
        })
      )

      _ = render(view)

      assert_raise ExUnit.AssertionError, fn ->
        assert_push_event(view, "maplibre:test-map:fly_to", %{center: _}, 150)
      end

      # And the commands topic subscription is gone as well.
      :ok = PhxMaplibre.fly_to("test-map", %{lng: 1.0, lat: 2.0}, pubsub: @pubsub)

      assert_raise ExUnit.AssertionError, fn ->
        assert_push_event(view, "maplibre:test-map:fly_to", %{center: _}, 150)
      end
    end

    test "re-attaching with subscribe: false keeps relaying but stops self-delivery", %{view: view} do
      :ok = PhxMaplibre.subscribe("test-map", pubsub: @pubsub)

      ready = %{"id" => "test-map", "event" => "ready", "payload" => ready_payload()}

      # Baseline: attached with the default `subscribe: true`, the view counts
      # the event it relayed to itself.
      render_hook(view, "maplibre:event", ready)
      assert_receive %Event{event: :ready}
      assert render(view) =~ "seen:1"

      send(view.pid, {:attach, "test-map", [pubsub: @pubsub, subscribe: false]})
      _ = render(view)

      render_hook(view, "maplibre:event", ready)

      # The relay still works for everyone else...
      assert_receive %Event{map_id: "test-map", event: :ready}

      # ...but the view is no longer a subscriber, so its count stands still.
      # A silently broken unsubscribe makes this "seen:2".
      assert render(view) =~ "seen:1"
    end

    test "re-attaching with a different topic prefix moves the subscriptions", %{view: view} do
      send(view.pid, {:attach, "test-map", [pubsub: @pubsub, topic_prefix: "custom"]})
      _ = render(view)

      # The old default-prefix subscription must be gone (the leak regression).
      :ok = PhxMaplibre.fly_to("test-map", %{lng: 1.0, lat: 2.0}, pubsub: @pubsub)

      assert_raise ExUnit.AssertionError, fn ->
        assert_push_event(view, "maplibre:test-map:fly_to", %{center: _}, 150)
      end

      :ok =
        PhxMaplibre.fly_to("test-map", %{lng: 1.0, lat: 2.0},
          pubsub: @pubsub,
          topic_prefix: "custom"
        )

      assert_push_event(view, "maplibre:test-map:fly_to", %{center: _})
    end
  end

  describe "drop telemetry and log throttling" do
    setup do
      test_pid = self()
      handler_id = "test-event-dropped-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:phx_maplibre, :event_dropped],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "a disallowed event fires event_dropped telemetry with the reason", %{view: view} do
      :ok = PhxMaplibre.subscribe("test-map", pubsub: @pubsub)

      send(view.pid, {:attach, "test-map", [pubsub: @pubsub, events: [:ready]]})
      _ = render(view)

      render_hook(view, "maplibre:event", %{
        "id" => "test-map",
        "event" => "feature_selected",
        "payload" => %{"id" => "f1"}
      })

      assert_receive {:telemetry, [:phx_maplibre, :event_dropped], %{system_time: _},
                       %{map_id: "test-map", reason: :disallowed_event}}
    end

    test "an oversized payload fires event_dropped telemetry with the reason", %{view: view} do
      :ok = PhxMaplibre.subscribe("test-map", pubsub: @pubsub)

      render_hook(view, "maplibre:event", %{
        "id" => "test-map",
        "event" => "feature_selected",
        "payload" => selected_payload("f1", %{"blob" => String.duplicate("x", 600_000)})
      })

      assert_receive {:telemetry, [:phx_maplibre, :event_dropped], %{system_time: _},
                       %{map_id: "test-map", reason: :oversized}}
    end

    test "an invalid payload fires event_dropped telemetry with the reason", %{view: view} do
      :ok = PhxMaplibre.subscribe("test-map", pubsub: @pubsub)

      render_hook(view, "maplibre:event", %{
        "id" => "test-map",
        "event" => "move_end",
        "payload" => %{}
      })

      assert_receive {:telemetry, [:phx_maplibre, :event_dropped], %{system_time: _},
                       %{map_id: "test-map", reason: :invalid_payload}}
    end

    test "repeated identical rejections still fire telemetry every time", %{view: view} do
      :ok = PhxMaplibre.subscribe("test-map", pubsub: @pubsub)

      oversized_event = %{
        "id" => "test-map",
        "event" => "feature_selected",
        "payload" => %{"id" => "f1", "blob" => String.duplicate("x", 600_000)}
      }

      render_hook(view, "maplibre:event", oversized_event)
      render_hook(view, "maplibre:event", oversized_event)

      assert_receive {:telemetry, [:phx_maplibre, :event_dropped], _,
                       %{map_id: "test-map", reason: :oversized}}

      assert_receive {:telemetry, [:phx_maplibre, :event_dropped], _,
                       %{map_id: "test-map", reason: :oversized}}
    end
  end

  defp ready_payload do
    %{
      "bounds" => %{"west" => 13.0, "south" => 52.0, "east" => 14.0, "north" => 53.0},
      "center" => %{"lng" => 13.5, "lat" => 52.5},
      "zoom" => 11
    }
  end

  defp selected_payload(id, extra) do
    %{
      "id" => id,
      "kind" => "point",
      "lng" => 13.4,
      "lat" => 52.5,
      "feature" => %{"type" => "Feature"}
    }
    |> Map.merge(Map.new(extra))
  end
end
