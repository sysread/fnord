defmodule Sandbox.NoSandbox do
  @moduledoc """
  Direct, non-isolated implementation for Sandbox.
  """

  @behaviour Sandbox

  @impl true
  def prepare_sandbox(_sandbox_name, context) do
    {:ok, %{root: context[:source_root]}}
  end

  @impl true
  def sandbox_path(state) do
    state[:root]
  end

  @impl true
  def finalize_sandbox_commit(_state), do: :ok

  @impl true
  def finalize_sandbox_discard(_state), do: :ok

  @impl true
  def cleanup_sandbox(_state), do: :ok
end
