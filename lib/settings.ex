defmodule Settings do
  defstruct [:path, :data]

  def new() do
    %Settings{path: settings_file()}
    |> slurp()
  end

  @doc """
  Get the path to the store root directory.
  """
  def home() do
    path = "#{System.get_env("HOME")}/.fnord"
    File.mkdir_p!(path)
    path
  end

  @doc """
  Get the path to the settings file.
  """
  def settings_file() do
    path = "#{home()}/settings.json"

    if !File.exists?(path) do
      File.write!(path, "{}")
    end

    path
  end

  @doc """
  Get a value from the settings store.
  """
  def get(settings, key, default \\ nil) do
    key = make_key(key)
    Map.get(settings.data, key, default)
  end

  @doc """
  Set a value in the settings store.
  """
  def set(settings, key, value) do
    key = make_key(key)

    %Settings{settings | data: Map.put(settings.data, key, value)}
    |> IO.inspect(label: "SETTINGS")
    |> spew()
  end

  defp slurp(settings) do
    %Settings{settings | data: File.read!(settings.path) |> Jason.decode!()}
  end

  defp spew(settings) do
    File.write!(settings.path, Jason.encode!(settings.data))
    settings
  end

  defp make_key(key) when is_atom(key), do: Atom.to_string(key)
  defp make_key(key), do: key
end
