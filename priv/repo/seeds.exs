# Idempotent seed script (design §8, D17): creates placeholder kids and
# demo chores only when the tables are empty; never modifies existing
# rows. Runs via `mix ecto.setup` or `mix run priv/repo/seeds.exs`.
# Real kid names are entered through admin and never belong here — this
# is a public repo.

alias BearCub.Chores
alias BearCub.Chores.{Chore, Kid}
alias BearCub.LocalTime
alias BearCub.Repo

if Repo.aggregate(Kid, :count) == 0 do
  for attrs <- [
        %{name: "Kid A", color: "#f59e0b", position: 0},
        %{name: "Kid B", color: "#0ea5e9", position: 1}
      ] do
    %Kid{} |> Kid.changeset(attrs) |> Repo.insert!()
  end
end

demo_chores = %{
  "morning" => [
    {"Brush Teeth", "🪥"},
    {"Make Bed", "🛏️"},
    {"Eat Breakfast", "🥣"},
    {"Get Dressed", "👕"},
    {"Pack Backpack", "🎒"}
  ],
  "evening" => [
    {"Brush Teeth", "🪥"},
    {"Pajamas On", "🌙"}
  ]
}

local_now = LocalTime.now()

if Repo.aggregate(Chore, :count) == 0 do
  for kid <- Repo.all(Kid),
      {routine, chores} <- demo_chores,
      {name, icon} <- chores do
    # create_chore/3 derives position and active_from (D86); this script
    # is an edge, so reading the clock here is fine
    {:ok, _chore} =
      Chores.create_chore(kid, %{name: name, icon: icon, routine: routine}, local_now)
  end
end
