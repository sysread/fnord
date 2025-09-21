defmodule Services.GlobalsTest do
  use Fnord.TestCase, async: true

  alias Services.Globals

  test "get falls back to Application.get_env/3 when no root or override" do
    assert :fallback == Globals.get_env(:some_app, :missing_key, :fallback)
  end

  test "put installs root automatically and get returns override" do
    :ok = Globals.put_env(:my_app, :foo, 42)
    assert 42 == Globals.get_env(:my_app, :foo, :fallback)
    assert self() == Globals.current_root()
  end

  test "delete_env removes the override only for this tree" do
    :ok = Globals.put_env(:my_app, :foo, 42)
    assert 42 == Globals.get_env(:my_app, :foo, :fallback)
    :ok = Globals.delete_env(:my_app, :foo)
    assert :fallback == Globals.get_env(:my_app, :foo, :fallback)
  end

  test "override shadows down the process stack for Services.Globals.Spawn.async descendants" do
    :ok = Globals.put_env(:my_app, :foo, 42)

    t = Services.Globals.Spawn.async(fn -> Globals.get_env(:my_app, :foo, :fallback) end)
    assert 42 == Task.await(t)
  end

  test "plain spawn/1 does not inherit (no proc_lib ancestors)" do
    :ok = Globals.put_env(:my_app, :foo, 42)

    parent = self()

    spawn(fn ->
      send(parent, {:seen, Globals.get_env(:my_app, :foo, :none)})
    end)

    assert_receive {:seen, :none}
    assert 42 == Globals.get_env(:my_app, :foo, :fallback)
  end

  test "explicit install_root/0 then child resolves and PD-caches" do
    :ok = Globals.install_root()
    :ok = Globals.put_env(:app, :k, :v)

    t =
      Services.Globals.Spawn.async(fn ->
        assert :v == Globals.get_env(:app, :k, :default)
        # PD cache path
        assert :v == Globals.get_env(:app, :k, :default)
        :ok
      end)

    assert :ok == Task.await(t)
  end

  test "cleanup on root DOWN wipes root marker and all data for that root" do
    parent = self()

    root =
      Services.Globals.Spawn.spawn(fn ->
        :ok = Globals.install_root()
        :ok = Globals.put_env(:my_app, :foo, 99)
        send(parent, {:root_started, self()})

        t = Services.Globals.Spawn.async(fn -> Globals.get_env(:my_app, :foo, :fallback) end)
        send(parent, {:child_value, Task.await(t)})

        Process.exit(self(), :normal)
      end)

    assert_receive {:root_started, ^root}
    assert_receive {:child_value, 99}

    # Give the server a tick to process :DOWN
    Process.sleep(50)

    refute :ets.member(:globals_roots, root)

    ms = [{{{root, :_, :_}, :_}, [], [true]}]
    assert 0 == :ets.select(:globals_data, ms) |> length()
  end

  test "concurrent Services.Globals.Spawn.async children see the same override (no races)" do
    :ok = Globals.put_env(:app, :k, :v)

    tasks =
      for _ <- 1..20 do
        Services.Globals.Spawn.async(fn -> Globals.get_env(:app, :k, :default) end)
      end

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.all?(results, &(&1 == :v))
  end

  test "fallback still hits Application.get_env/3 when override missing" do
    Services.Globals.put_env(:another_app, :k, :from_app)

    try do
      assert :from_app == Globals.get_env(:another_app, :k, :fallback)
    after
      Services.Globals.delete_env(:another_app, :k)
    end
  end
end
