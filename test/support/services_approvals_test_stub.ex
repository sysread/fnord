defmodule Services.Approvals.TestStub do
  @moduledoc """
  Test stub implementation for Services.Approvals behavior.

  By default, always approves requests. Tests can use Mox to override
  specific behaviors as needed.
  """

  @behaviour Services.Approvals.Workflow

  @impl Services.Approvals.Workflow
  def confirm(_opts, state), do: {:approved, state}
end
