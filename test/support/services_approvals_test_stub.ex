defmodule Services.Approvals.TestStub do
  @moduledoc """
  Test stub implementation for Services.Approvals behavior.

  By default, always approves requests. Tests can use Mox to override
  specific behaviors as needed.
  """

  @behaviour Services.Approvals

  @impl Services.Approvals
  def init do
    # Simple empty state for tests
    %{}
  end

  @impl Services.Approvals
  def confirm(_opts, state) do
    {{:ok, :approved}, state}
  end

  @impl Services.Approvals
  def is_approved?(_tag, _subject, state) do
    {true, state}
  end

  @impl Services.Approvals
  def approve(_scope, _tag, _subject, state) do
    {{:ok, :approved}, state}
  end

  @impl Services.Approvals
  def enable_auto_approval(_tag, _subject, state) do
    {{:ok, :approved}, state}
  end
end
