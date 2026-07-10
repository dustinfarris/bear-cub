defmodule BearCub.Repo do
  use Ecto.Repo,
    otp_app: :bear_cub,
    adapter: Ecto.Adapters.SQLite3
end
