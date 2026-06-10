defmodule Services.InstanceTest do
  use Fnord.TestCase, async: false

  # These tests exercise the instance-checkout model: an owner process calls
  # Fnord.Instance.start_link/1, becoming a Services.Globals root with its own
  # config scope and its own copies of tree-scoped services. Owners are raw
  # spawns, so they carry no :"$ancestors" and cannot accidentally inherit the
  # test process's root - they are true siblings of the test's own tree.

  test "sibling instances have isolated service state and config" do
    {owner_a, probes_a} = checkout(project: "alpha")
    {owner_b, probes_b} = checkout(project: "beta")

    # Both instances saw the same key for the first time - with a shared
    # (VM-global) Once, the second checkout would have returned false.
    assert probes_a.set == true
    assert probes_b.set == true

    # Each instance resolves its own config overrides.
    assert probes_a.project == "alpha"
    assert probes_b.project == "beta"

    # The instances run distinct service processes.
    refute probes_a.agent == probes_b.agent

    # The test's own tree (its own Fnord.Instance checkout via Fnord.TestCase)
    # is a third, independent scope.
    assert Services.Once.set("instance_test_shared_key") == true

    shutdown(owner_a)
    shutdown(owner_b)
  end

  test "checkout boots the full service roster" do
    {owner, _probes} = checkout([])

    roster = [
      UI.Queue,
      Services.Once,
      Services.Notes,
      Services.Conversation.Interrupts,
      Services.BackupFile,
      Services.TempFile,
      Services.FileCache,
      Services.NamePool,
      Services.Approvals,
      Services.Approvals.Gate
    ]

    pids =
      run_in(owner, fn ->
        Enum.map(roster, fn service -> {service, Services.Instance.whereis(service)} end)
      end)

    for {service, pid} <- pids do
      assert is_pid(pid), "#{inspect(service)} not registered in instance tree"
    end

    # None of the instance's services are the test tree's copies.
    for {service, pid} <- pids do
      refute Services.Instance.whereis(service) == pid,
             "#{inspect(service)} is shared with the test tree"
    end

    shutdown(owner)
  end

  test "descendants of an instance resolve the instance's services" do
    {owner, probes} = checkout([])

    # A Task started inside the instance resolves the instance's Once through
    # :"$ancestors", landing on the same agent the owner registered.
    result =
      run_in(owner, fn ->
        fn -> Services.Once.set("from_descendant") end
        |> Task.async()
        |> Task.await()
      end)

    assert result == true

    # And the key is recorded in the instance's agent, not the test's.
    assert run_in(owner, fn -> Services.Once.get("from_descendant") end) == {:ok, true}
    assert Services.Once.get("from_descendant") == {:error, :not_seen}
    assert Process.alive?(probes.agent)

    shutdown(owner)
  end

  test "instance services die with their owner" do
    {owner, probes} = checkout([])
    assert Process.alive?(probes.agent)

    ref = Process.monitor(probes.agent)
    shutdown(owner)

    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
  end

  test "service calls raise outside any instance tree" do
    parent = self()

    spawn(fn ->
      result =
        try do
          Services.Once.set("no_tree_key")
        rescue
          e -> {:raised, Exception.message(e)}
        end

      send(parent, {:result, result})
    end)

    assert_receive {:result, {:raised, msg}}, 1_000
    assert msg =~ "not running in this process tree"
  end

  # ----------------------------------------------------------------------------
  # Checkout harness: spawn an owner, check out a Fnord.Instance inside it,
  # collect standard probes, and keep the owner alive until shutdown/1.
  # ----------------------------------------------------------------------------

  defp checkout(config) do
    parent = self()

    owner =
      spawn_link(fn ->
        {:ok, _sup} = Fnord.Instance.start_link(config: config)

        probes = %{
          set: Services.Once.set("instance_test_shared_key"),
          project: Services.Globals.get_env(:fnord, :project),
          agent: Services.Instance.fetch!(Services.Once)
        }

        send(parent, {self(), probes})
        owner_loop(parent)
      end)

    receive do
      {^owner, probes} -> {owner, probes}
    after
      1_000 -> flunk("instance checkout timed out")
    end
  end

  defp owner_loop(parent) do
    receive do
      {:run, ref, fun} ->
        send(parent, {ref, fun.()})
        owner_loop(parent)

      :shutdown ->
        :ok
    end
  end

  defp run_in(owner, fun) do
    ref = make_ref()
    send(owner, {:run, ref, fun})

    receive do
      {^ref, result} -> result
    after
      1_000 -> flunk("run_in timed out")
    end
  end

  defp shutdown(owner) do
    ref = Process.monitor(owner)
    send(owner, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^owner, _} -> :ok
    after
      1_000 -> flunk("instance owner failed to stop")
    end
  end
end
