defmodule Util.Exec do
  @moduledoc """
  Seam over subprocess execution for outward-facing commands that have no
  dedicated facade of their own (git goes through `GitCli`; everything else
  that shells out to affect the world outside the BEAM - desktop
  notifications, escript installs - routes through this module). `impl/0`
  resolves the `:exec` Globals key (same dispatch pattern as `:http_client`),
  defaulting to the System passthrough in the sibling Default module. Tests
  get the Mox mock with NO default stub, so a test that reaches an unscripted
  subprocess fails loudly instead of spawning one.
  """

  @doc """
  Runs `executable` with `args`. Mirrors `System.cmd/3`: returns the
  collected output and the exit status.
  """
  @callback cmd(String.t(), [String.t()], keyword) :: {Collectable.t(), non_neg_integer()}

  @doc """
  Resolves `name` on the PATH. Mirrors `System.find_executable/1`.
  """
  @callback find_executable(String.t()) :: String.t() | nil

  def impl() do
    Services.Globals.get_env(:fnord, :exec, Util.Exec.Default)
  end

  @spec cmd(String.t(), [String.t()], keyword) :: {Collectable.t(), non_neg_integer()}
  def cmd(executable, args, opts \\ []), do: impl().cmd(executable, args, opts)

  @spec find_executable(String.t()) :: String.t() | nil
  def find_executable(name), do: impl().find_executable(name)
end

defmodule Util.Exec.Default do
  @moduledoc false

  @behaviour Util.Exec

  @impl Util.Exec
  def cmd(executable, args, opts), do: System.cmd(executable, args, opts)

  @impl Util.Exec
  def find_executable(name), do: System.find_executable(name)
end
