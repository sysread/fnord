defmodule Frobs do
  defstruct [
    :name,
    :path
  ]

  @home Path.join(System.user_home!(), ["fnord", "tools"])

  def init_frobs do
    File.mkdir_p!(@home)
  end

  def new(name) do
    init_frobs()

    with {:ok, path} <- find(name) do
      {:ok, %__MODULE__{name: name, path: path}}
    end
  end

  def init(name) do
    path = Path.join(@home, name)

    if File.exists?(path) do
      {:error, :exists}
    else
      # TODO init skeleton
      File.mkdir_p!(path)
      {:ok, %__MODULE__{name: name, path: path}}
    end
  end

  def find(name) do
    path = Path.join(@home, name)

    if File.exists?(path) do
      {:ok, path}
    else
      {:error, :not_found}
    end
  end
end
