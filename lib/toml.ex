defmodule Fnord.Toml do
  @moduledoc """
  TOML parsing utilities.

  This module is a wrapper around the third-party `:toml` package.

  The rest of the codebase should depend on this wrapper rather than calling
  the external library directly. This keeps TOML usage consistent across
  features and makes it easy to swap parser implementations later.

  All functions return `{:ok, map}` on success and `{:error, reason}` on failure.
  """

  @type decode_error ::
          {:toml_decode_error, String.t()}
          | {:toml_file_error, path :: String.t(), reason :: term()}

  @spec decode(binary) :: {:ok, map()} | {:error, decode_error}
  def decode(toml) when is_binary(toml) do
    toml
    |> Toml.decode()
    |> case do
      {:ok, data} when is_map(data) ->
        {:ok, data}

      {:error, reason} ->
        {:error, {:toml_decode_error, format_decode_error(reason)}}
    end
  end

  @spec decode_file(String.t()) :: {:ok, map()} | {:error, decode_error}
  def decode_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> Toml.decode(filename: path)
        |> case do
          {:ok, data} when is_map(data) ->
            {:ok, data}

          {:error, reason} ->
            {:error, {:toml_decode_error, format_decode_error(reason)}}
        end

      {:error, reason} ->
        {:error, {:toml_file_error, path, reason}}
    end
  end

  defp format_decode_error(reason) do
    if is_binary(reason) do
      reason
    else
      inspect(reason)
    end
  end
end
