defmodule GsdTracker.Resources.FlockTest do
  use GsdTracker.DataCase, async: true

  test "creates flock with members" do
    flock =
      GsdTracker.Flock
      |> Ash.Changeset.for_create(:create, %{member_count: 2})
      |> Ash.create!(domain: GsdTracker.Ash)

    for status <- [:surveillance, :charging] do
      GsdTracker.GSD
      |> Ash.Changeset.for_create(:create, %{
        commissioning_date: DateTime.utc_now() |> DateTime.truncate(:second),
        flock_id: flock.id,
        status: status
      })
      |> Ash.create!(domain: GsdTracker.Ash)
    end

    flock =
      GsdTracker.Flock
      |> Ash.Query.for_read(:read)
      |> Ash.Query.load(:members)
      |> Ash.read!(domain: GsdTracker.Ash)
      |> Enum.find(&(&1.id == flock.id))

    assert flock.member_count == 2
    assert length(flock.members) == 2
  end
end
