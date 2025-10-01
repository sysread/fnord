defmodule Browser do
  @moduledoc false
  @callback open(String.t()) :: :ok | {:error, term()}
end
