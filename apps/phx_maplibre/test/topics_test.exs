defmodule PhxMaplibre.TopicsTest do
  use ExUnit.Case, async: true

  alias PhxMaplibre.Topics

  test "default prefix" do
    assert Topics.events_topic("m1") == "phx_maplibre:m1:events"
    assert Topics.commands_topic("m1") == "phx_maplibre:m1:commands"
  end

  test "custom prefix" do
    assert Topics.events_topic("m1", "custom") == "custom:m1:events"
    assert Topics.commands_topic("m1", "custom") == "custom:m1:commands"
  end

  test "facade topic helpers honor :topic_prefix" do
    assert PhxMaplibre.events_topic("m1") == "phx_maplibre:m1:events"
    assert PhxMaplibre.commands_topic("m1", topic_prefix: "x") == "x:m1:commands"
  end
end
