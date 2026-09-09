defmodule GsdTracker.Resources.GSDTest do
  use GsdTracker.DataCase, async: true

  test "creates gsd with flock relationship and reads by id" do
    flock =
      GsdTracker.Flock
      |> Ash.Changeset.for_create(:create, %{member_count: 1})
      |> Ash.create!(domain: GsdTracker.Ash)

    gsd =
      GsdTracker.GSD
      |> Ash.Changeset.for_create(:create, %{
        commissioning_date: DateTime.utc_now() |> DateTime.truncate(:second),
        flock_id: flock.id,
        status: :simulating,
        speed_kmh: Decimal.new("70.0")
      })
      |> Ash.create!(domain: GsdTracker.Ash)

    fetched =
      GsdTracker.GSD
      |> Ash.Query.for_read(:by_id, %{id: gsd.id})
      |> Ash.Query.load(:flock)
      |> Ash.read_one!(domain: GsdTracker.Ash)

    assert fetched.id == gsd.id
    assert fetched.flock_id == flock.id
    assert fetched.flock.id == flock.id
    assert fetched.status == :simulating
  end
end
