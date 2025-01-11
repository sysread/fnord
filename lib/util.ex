defmodule Util do
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
end
