defmodule Browser do
  @moduledoc """
  Behaviour for launching a browser (or equivalent) to open a URL.

  Abstracts OS-specific browser launch semantics behind `open/1`.
  Tests can inject a no-op or recording mock; production uses `Browser.Default`.

  Introduced: M3 (DI boundary for browser launching).
  """
  @callback open(String.t()) :: :ok | {:error, term()}
end
