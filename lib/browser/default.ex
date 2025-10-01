defmodule Browser.Default do
  @moduledoc """
  Default OS-aware browser launcher.

  macOS: uses `open`.
  Linux: uses `xdg-open`.
  Fallback: prints the URL via `UI.info/2` when a suitable launcher is not available.

  Notes:
    - Designed for DI; tests should inject a mock instead of using this module.

  Introduced: M3.
  """
  @behaviour Browser

  @impl true
  def open(url) when is_binary(url) do
    case :os.type() do
      {:unix, :darwin} ->
        launch(["open", url])

      {:unix, _linux} ->
        launch(["xdg-open", url])

      _ ->
        UI.info("Open this URL in your browser to continue", url)
        :ok
    end
  end

  defp launch([cmd, arg]) do
    case System.find_executable(cmd) do
      nil ->
        UI.info("Open this URL in your browser to continue", arg)
        :ok

      _ ->
        {_out, _} = System.cmd(cmd, [arg])
        :ok
    end
  end
end
