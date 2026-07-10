# BearCub

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Seed data

`priv/repo/seeds.exs` is idempotent and never modifies existing rows: it
creates two placeholder kids plus demo chores only when the tables are
empty. `mix ecto.setup` / `mix ecto.reset` run it automatically, or run
it directly:

    mix run priv/repo/seeds.exs

Real kid names are entered later through admin and never belong in this
public repo. Production does not seed at boot (design D17): the deployed
box gets its placeholder rows once at first deploy.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
