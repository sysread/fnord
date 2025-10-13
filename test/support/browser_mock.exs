defmodule Fnord.BrowserMock do
  @behaviour Browser
  @impl true
  def open(_url), do: :ok
end
