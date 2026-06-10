defmodule Services.Instance do
  @moduledoc """
  Tree-scoped service registry.

  Maps a service module to the pid serving the *current process tree*, using
  `Services.Globals`' root resolution for scoping. This is the process
  counterpart to tree-scoped config: instead of registering a service under a
  VM-global atom name (`name: __MODULE__`), a service registers its pid under
  the current tree's root. Two process trees (two tests, or two checked-out
  `Fnord.Instance`s) each get their own copy of the service, invisible to one
  another. In production there is exactly one tree (rooted at the escript's
  main process), so behavior is identical to a named singleton.

  Registration entries live in the Globals data table, so they are wiped
  automatically when the tree's root process dies.

  Resolution relies on `:"$ancestors"`, which only proc_lib-spawned processes
  (GenServer, Supervisor, Task, Agent) carry. A raw `spawn`ed process, or a
  process whose ancestry chain leads to a dead root, cannot resolve any
  instance and `fetch!/1` will raise.
  """

  @doc """
  Register `pid` as the instance of `service` for the current process tree.
  Typically called from the service's own `start_link`, in which case the
  registration is performed by the *starter* (the owner process or a
  supervisor), scoping the service to the starter's tree. A supervisor
  restarting the service re-runs registration and overwrites the entry with
  the new pid.
  """
  @spec register(module(), pid()) :: :ok
  def register(service, pid) do
    Services.Globals.put_env(:fnord, {:instance_service, service}, pid)
  end

  @doc """
  Return the pid registered for `service` in the current process tree, or nil
  when the service is not running in this tree (or the registered pid has
  died).
  """
  @spec whereis(module()) :: pid() | nil
  def whereis(service) do
    case Services.Globals.get_override(:fnord, {:instance_service, service}) do
      pid when is_pid(pid) -> alive_or_nil(pid)
      _ -> nil
    end
  end

  @doc """
  Like `whereis/1`, but raises when the service is not running in the current
  tree. Services use this to resolve their own instance in their API
  functions; a raise here means the calling process's tree never started the
  service, or the caller is not parented under any instance root.
  """
  @spec fetch!(module()) :: pid()
  def fetch!(service) do
    case whereis(service) do
      nil ->
        raise "#{inspect(service)} is not running in this process tree. " <>
                "It is tree-scoped: boot it via Fnord.Instance (or start it " <>
                "directly), and call it from a descendant of that tree's root."

      pid ->
        pid
    end
  end

  @doc """
  All services registered in the current process tree, sorted by module
  name. Dead pids are excluded. Introspection surface for debugging and
  roster assertions in tests.
  """
  @spec registered() :: [module()]
  def registered() do
    :fnord
    |> Services.Globals.overrides()
    |> Enum.flat_map(fn
      {{:instance_service, service}, pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          [service]
        else
          []
        end

      _other ->
        []
    end)
    |> Enum.sort()
  end

  @doc """
  `GenServer.call/3` against the tree's instance of `service`. Raises (via
  `fetch!/1`) when the service is not running in the caller's tree, matching
  the crash semantics of a call to an unregistered name.
  """
  @spec call(module(), term(), timeout()) :: term()
  def call(service, msg, timeout \\ 5000) do
    service
    |> fetch!()
    |> GenServer.call(msg, timeout)
  end

  @doc """
  `GenServer.cast/2` against the tree's instance of `service`. Silently drops
  the message when the service is not running in the caller's tree, matching
  the fire-and-forget semantics of a cast to an unregistered name.
  """
  @spec cast(module(), term()) :: :ok
  def cast(service, msg) do
    case whereis(service) do
      nil -> :ok
      pid -> GenServer.cast(pid, msg)
    end
  end

  defp alive_or_nil(pid) do
    if Process.alive?(pid) do
      pid
    else
      nil
    end
  end
end
