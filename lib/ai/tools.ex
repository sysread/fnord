defmodule AI.Tools do
  @type agent :: %{
          required(:ai) => AI.t(),
          required(:opts) => [
            question: String.t()
          ]
        }

  @callback spec() :: map()
  @callback call(agent(), map()) :: {:ok, String.t()}
end
