defmodule BearCub.MigrationTestRepo do
  @moduledoc """
  A throwaway repo, pointed at a scratch SQLite file per test, used to
  exercise real migration files against seeded data — verifying rebuilds
  preserve history without touching the sandboxed `BearCub.Repo`.
  """
  use Ecto.Repo, otp_app: :bear_cub, adapter: Ecto.Adapters.SQLite3
end
