defmodule Util do
  @doc """
  Convenience wrapper for `Task.async_stream/3` with the default optiosn for
  concurrency and timeout set to `Application.get_env(:fnord, :workers)` and
  `:infinity`, respectively.
  """
  def async_stream(enumerable, fun, options \\ []) do
    opts =
      [timeout: :infinity]
      |> Keyword.merge(options)

    Task.async_stream(enumerable, fun, opts)
  end

  @doc """
  Converts all string keys in a map to atoms, recursively.
  """
  def string_keys_to_atoms(list) when is_list(list) do
    list |> Enum.map(&string_keys_to_atoms/1)
  end

  def string_keys_to_atoms(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} ->
      converted_key =
        if is_binary(key) do
          String.to_atom(key)
        else
          key
        end

      converted_value =
        cond do
          is_map(value) -> string_keys_to_atoms(value)
          is_list(value) -> string_keys_to_atoms(value)
          true -> value
        end

      {converted_key, converted_value}
    end)
    |> Enum.into(%{})
  end

  def string_keys_to_atoms(value), do: value
end
