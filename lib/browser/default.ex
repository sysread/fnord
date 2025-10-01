defmodule Browser.Default do
  @moduledoc false
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
