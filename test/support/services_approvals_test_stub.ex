defmodule StubApprovals do
  @moduledoc """
  Test stub implementation for Services.Approvals.Workflow.

  By default, always approves requests. Tests can override behavior with :meck or Mox if needed.
  """

  @behaviour Services.Approvals.Workflow

  @impl Services.Approvals.Workflow
  def confirm(state, _args), do: {:approved, state}
end
