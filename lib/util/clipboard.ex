defmodule Util.Clipboard do
  @moduledoc """
  Seam over the system clipboard. The `Clipboard` hex package shells out to
  the platform's clipboard utility (pbcopy/xclip/etc.), so copying is an
  outward-facing side effect: it overwrites whatever the user currently has
  on their clipboard. All clipboard writes route through this module so tests
  can substitute a `Mox` double instead of clobbering the developer's
  clipboard mid-suite. `impl/0` resolves the `:clipboard` Globals key (same
  dispatch pattern as `:http_client`), defaulting to the passthrough in
  the sibling Default module.
  """

  @doc """
  Copies `text` to the system clipboard. Mirrors the hex package's contract:
  returns the input on success (so it can be piped), or an error tuple when
  no clipboard utility is available.
  """
  @callback copy(String.t()) :: String.t() | {:error, term()}

  def impl() do
    Services.Globals.get_env(:fnord, :clipboard, Util.Clipboard.Default)
  end

  @spec copy(String.t()) :: String.t() | {:error, term()}
  def copy(text), do: impl().copy(text)
end

defmodule Util.Clipboard.Default do
  @moduledoc false

  @behaviour Util.Clipboard

  @impl Util.Clipboard
  def copy(text), do: Clipboard.copy(text)
end
