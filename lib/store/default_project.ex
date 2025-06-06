defmodule Store.DefaultProject do
  def store_path do
    path = Store.store_home() |> Path.join("default")
    if !File.exists?(path), do: File.mkdir_p!(path)
    path
  end
end
