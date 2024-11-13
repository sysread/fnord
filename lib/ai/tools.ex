defmodule AI.Tools do
  @type agent :: AI.Agent.Answers.t()

  @callback spec() :: map()
  @callback call(agent(), map()) :: {:ok, String.t()}
end
