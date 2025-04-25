defmodule Util do
  @doc """
  Convenience wrapper for `Task.async_stream/3` with the default optiosn for
  concurrency and timeout set to `Application.get_env(:fnord, :workers)` and
  `:infinity`, respectively.
  """
  def async_stream(enumerable, fun, options \\ []) do
    opts = Keyword.merge([timeout: :infinity], options)
    Task.async_stream(enumerable, fun, opts)
  end

  def async_filter(enumerable, fun) do
    enumerable
    |> async_stream(fn item ->
      if fun.(item) do
        item
      else
        :skip
      end
    end)
    |> Stream.filter(fn
      {:ok, :skip} -> false
      {:ok, _} -> true
      _ -> false
    end)
    |> Stream.map(fn {:ok, item} -> item end)
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

  def get_running_version do
    {:ok, vsn} = :application.get_key(:fnord, :vsn)
    to_string(vsn)
  end

  def get_latest_version do
    case HTTPoison.get("https://hex.pm/api/packages/fnord", [], follow_redirect: true) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        body
        |> Jason.decode()
        |> case do
          {:ok, %{"latest_version" => version}} -> {:ok, version}
          _ -> :error
        end

      {:ok, %HTTPoison.Response{status_code: code}} ->
        IO.warn("Hex API request failed with status #{code}")
        {:error, :api_request_failed}

      {:error, %HTTPoison.Error{reason: reason}} ->
        IO.warn("Hex API request error: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
