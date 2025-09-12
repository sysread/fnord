defmodule UI.Output do
  @moduledoc """
  Behaviour for UI output operations.

  This abstraction allows different implementations for production (UI.Queue/Owl.IO)
  and testing (simple IO that can be captured).
  """

  @callback puts(iodata()) :: :ok
  @callback log(atom(), iodata()) :: :ok
  @callback interact((-> any())) :: any()
  @callback choose(String.t(), list()) :: any()
  @callback choose(String.t(), list(), non_neg_integer(), any()) :: any()
  @callback prompt(String.t()) :: String.t() | {:error, atom()}
  @callback prompt(String.t(), keyword()) :: String.t() | {:error, atom()}
  @callback confirm(String.t()) :: boolean()
  @callback confirm(String.t(), boolean()) :: boolean()
  @callback newline() :: :ok
  @callback box(iodata(), keyword()) :: :ok
  @callback flush() :: :ok
end
