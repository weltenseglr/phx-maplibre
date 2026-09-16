defmodule Demo.Map.MockDataTest do
  use ExUnit.Case, async: true

  alias Demo.Map.MockData

  test "includes distinct venues sharing an exact coordinate" do
    venues =
      MockData.all_venues()
      |> Enum.filter(&String.starts_with?(&1.title, "Shared Entrance"))

    assert length(venues) == 3
    assert venues |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 3
    assert venues |> Enum.map(&{&1.lng, &1.lat}) |> Enum.uniq() == [{13.405, 52.52}]
  end

  test "keeps coordinates stable across repeated reads" do
    first = Map.new(MockData.all_venues(), &{&1.id, {&1.lng, &1.lat}})
    second = Map.new(MockData.all_venues(), &{&1.id, {&1.lng, &1.lat}})

    assert first == second
  end
end
