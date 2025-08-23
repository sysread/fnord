defmodule Services.Approvals.Workflow do
  @type state :: term
  @type args :: term

  @type decision ::
          {:approved, state}
          | {:denied, binary, state}
          | {:error, binary, state}

  @callback confirm(state, args) :: decision
end
