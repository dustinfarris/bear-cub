defmodule BearCub.NotificationsTest do
  use BearCub.DataCase

  import BearCub.ChoresFixtures
  import BearCub.RewardsFixtures
  import ExUnit.CaptureLog

  alias BearCub.Chores
  alias BearCub.Notifications
  alias BearCub.Rewards

  @url "https://ntfy.example/secret-topic"
  @now ~U[2026-07-24 15:00:00Z]

  setup do
    original = Application.get_env(:bear_cub, :ntfy_url)
    on_exit(fn -> Application.put_env(:bear_cub, :ntfy_url, original) end)
    Application.put_env(:bear_cub, :ntfy_url, @url)
    :ok
  end

  # Stubs the ntfy endpoint and forwards each push to the test process.
  defp capture_pushes do
    test = self()

    Req.Test.stub(Notifications, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:push, conn, body})
      Plug.Conn.send_resp(conn, 200, "{}")
    end)
  end

  # Runs `fun` and blocks until the push it dispatched has finished, so
  # a captured log covers the whole request.
  defp await_push(fun) do
    assert {:ok, pid} = fun.()
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
  end

  describe "push/1" do
    test "POSTs the message to the configured topic URL with a title" do
      capture_pushes()

      await_push(fn -> Notifications.push("hello") end)

      assert_receive {:push, conn, "hello"}
      assert conn.method == "POST"
      assert conn.host == "ntfy.example"
      assert conn.request_path == "/secret-topic"
      assert Plug.Conn.get_req_header(conn, "title") == ["Bear Cub"]
    end

    test "is a no-op when no topic URL is configured" do
      Application.put_env(:bear_cub, :ntfy_url, nil)
      capture_pushes()

      assert Notifications.push("hello") == :ignore
      refute_receive {:push, _, _}, 50
    end

    test "a transport failure logs the message, never the URL" do
      Req.Test.stub(Notifications, &Req.Test.transport_error(&1, :econnrefused))

      log = capture_log(fn -> await_push(fn -> Notifications.push("Kid A did a thing") end) end)

      assert log =~ "ntfy push failed"
      assert log =~ "Kid A did a thing"
      refute log =~ "secret-topic"
      refute log =~ "ntfy.example"
    end

    test "a non-2xx response logs the status, never the URL" do
      Req.Test.stub(Notifications, &Plug.Conn.send_resp(&1, 403, "forbidden"))

      log = capture_log(fn -> await_push(fn -> Notifications.push("hello") end) end)

      assert log =~ "ntfy push failed"
      assert log =~ "status=403"
      refute log =~ "secret-topic"
    end
  end

  describe "chore completion" do
    setup do
      capture_pushes()
      kid = kid_fixture(%{name: "Kid A"})
      %{kid: kid}
    end

    test "a flagged chore pushes one line naming kid, icon and chore", %{kid: kid} do
      chore =
        chore_fixture(kid, %{name: "Brush teeth", icon: "🪥", routine: "morning"})
        |> flag()

      # a sibling keeps the routine incomplete, isolating the chore push
      chore_fixture(kid, %{name: "Make bed", icon: "🛏️", routine: "morning"})

      assert {:ok, _} = Chores.complete_chore(chore, @now, "kiosk")
      assert_receive {:push, _, "Kid A finished 🪥 Brush teeth"}
      refute_receive {:push, _, _}, 50
    end

    test "an unflagged chore pushes nothing", %{kid: kid} do
      chore = chore_fixture(kid, %{name: "Brush teeth", icon: "🪥", routine: "morning"})
      chore_fixture(kid, %{name: "Make bed", icon: "🛏️", routine: "morning"})

      assert {:ok, _} = Chores.complete_chore(chore, @now, "kiosk")
      refute_receive {:push, _, _}, 50
    end

    test "an admin on-behalf completion pushes like a kiosk one", %{kid: kid} do
      chore = chore_fixture(kid, %{name: "Brush teeth", icon: "🪥", routine: "morning"}) |> flag()
      chore_fixture(kid, %{name: "Make bed", icon: "🛏️", routine: "morning"})

      assert {:ok, _} = Chores.toggle_completion(chore, @now, "admin")
      assert_receive {:push, _, "Kid A finished 🪥 Brush teeth"}
    end

    test "a flagged extra pushes, with no routine push", %{kid: kid} do
      extra = chore_fixture(kid, %{name: "Rake leaves", icon: "🍂", routine: nil}) |> flag()

      assert {:ok, _} = Chores.complete_chore(extra, @now, "kiosk")
      assert_receive {:push, _, "Kid A finished 🍂 Rake leaves"}
      refute_receive {:push, _, _}, 50
    end

    test "finishing the last chore of a routine pushes a routine line regardless of flags",
         %{kid: kid} do
      first = chore_fixture(kid, %{name: "Brush teeth", icon: "🪥", routine: "evening"})
      last = chore_fixture(kid, %{name: "Pajamas", icon: "🌙", routine: "evening"})

      assert {:ok, _} = Chores.complete_chore(first, @now, "kiosk")
      refute_receive {:push, _, _}, 50

      assert {:ok, _} = Chores.complete_chore(last, @now, "kiosk")
      assert_receive {:push, _, "Kid A's evening routine is done"}
      refute_receive {:push, _, _}, 50
    end

    test "a flagged last chore pushes both its own line and the routine line", %{kid: kid} do
      only = chore_fixture(kid, %{name: "Brush teeth", icon: "🪥", routine: "morning"}) |> flag()

      assert {:ok, _} = Chores.complete_chore(only, @now, "kiosk")
      assert_receive {:push, _, "Kid A finished 🪥 Brush teeth"}
      assert_receive {:push, _, "Kid A's morning routine is done"}
    end

    test "undo and fail push nothing", %{kid: kid} do
      chore = chore_fixture(kid, %{name: "Brush teeth", icon: "🪥", routine: "morning"}) |> flag()

      assert {:ok, _} = Chores.complete_chore(chore, @now, "kiosk")
      assert_receive {:push, _, _}
      assert_receive {:push, _, _}

      assert {:ok, _} = Chores.undo_chore(chore, @now)
      refute_receive {:push, _, _}, 50

      assert {:ok, _} = Chores.complete_chore(chore, @now, "kiosk")
      assert_receive {:push, _, _}
      assert_receive {:push, _, _}

      assert {:ok, _} = Chores.fail_chore(chore, @now)
      refute_receive {:push, _, _}, 50
    end

    defp flag(chore) do
      {:ok, chore} = Chores.update_chore(chore, %{notify_on_complete?: true})
      chore
    end
  end

  describe "reward request" do
    setup do
      capture_pushes()
      %{kid: kid_fixture(%{name: "Kid A"})}
    end

    test "a kiosk ask pushes the kid, reward and price", %{kid: kid} do
      reward = reward_fixture(kid, %{name: "Ice cream", icon: "🍦", points: 20})

      assert {:ok, _} = Rewards.request_redemption(kid, reward, @now)
      assert_receive {:push, _, "Kid A asked for 🍦 Ice cream (20 pts)"}
    end

    test "a parent direct redeem pushes nothing", %{kid: kid} do
      reward = reward_fixture(kid, %{name: "Ice cream", icon: "🍦", points: 20})

      assert {:ok, _} = Rewards.direct_redeem(kid, reward, 100, @now)
      refute_receive {:push, _, _}, 50
    end
  end
end
