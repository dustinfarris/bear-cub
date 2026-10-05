defmodule BearCubWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use BearCubWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint BearCubWeb.Endpoint

      use BearCubWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import BearCubWeb.ConnCase
      import BearCub.ScheduleHelpers
    end
  end

  setup tags do
    BearCub.DataCase.setup_sandbox(tags)
    # D126: every LiveView test starts under a known schedule, so none
    # inherits the hour it happens to run at. `@tag :real_schedule` opts out.
    # Async modules skip it: they never mount a view, and a SQLite write
    # from several of them at once fails "Database busy".
    unless tags[:real_schedule] || tags[:async],
      do: BearCub.ScheduleHelpers.pin_default_schedule()

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
