defmodule DockerSandbox.CLI do
  @moduledoc false
  @callback cmd(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  @callback executable?(String.t()) :: boolean
  @spec cmd(String.t(), [String.t()], keyword) :: {String.t(), non_neg_integer()}
  def cmd(cmd, args, opts \\ []) do
    System.cmd(cmd, args, opts)
  end

  @spec executable?(String.t()) :: boolean
  def executable?(cmd) do
    System.find_executable(cmd) != nil
  end
end
