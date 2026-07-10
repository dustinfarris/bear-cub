# Idempotent seed script (design §8, D17): creates placeholder kids and
# demo chores only when the tables are empty; never modifies existing
# rows. Runs via `mix ecto.setup` or `mix run priv/repo/seeds.exs`.
# Real kid names are entered through admin and never belong here — this
# is a public repo.

alias BearCub.Chores.{Chore, Kid}
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

if Repo.aggregate(Chore, :count) == 0 do
  for kid <- Repo.all(Kid),
      {routine, chores} <- demo_chores,
      {{name, icon}, position} <- Enum.with_index(chores) do
    %Chore{kid_id: kid.id}
    |> Chore.changeset(%{name: name, icon: icon, routine: routine, position: position})
    |> Repo.insert!()
  end
end
