defmodule GsdTracker.Repo do
  use AshPostgres.Repo,
    otp_app: :demo_gsd_tracker,
    warn_on_missing_ash_functions?: false

  def min_pg_version do
    %Version{major: 17, minor: 0, patch: 0}
  end
end
