defmodule StubClipboard do
  @moduledoc """
  Default test implementation of `Util.Clipboard`: reports success (returns
  the input, matching the hex package's pipeable contract) without touching
  the developer's actual clipboard. Tests exercising the failure path stub
  `Util.Clipboard.Mock` with an error tuple instead.
  """

  @behaviour Util.Clipboard

  @impl Util.Clipboard
  def copy(text), do: text
end
