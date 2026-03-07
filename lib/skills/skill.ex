defmodule Skills.Skill do
  @moduledoc """
  A single skill definition loaded from a TOML file.

  Skills are defined on disk as TOML and loaded at runtime.

  Fields in the struct reflect the stable skill schema:
  - `name`, `description`, `model`, `tools`, `system_prompt` are required
  - `response_format` is optional

  Validation is performed when loading a skill from TOML.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          model: String.t(),
          tools: [String.t()],
          system_prompt: String.t(),
          response_format: map() | nil
        }

  defstruct [:name, :description, :model, :tools, :system_prompt, :response_format]

  @type decode_error ::
          {:missing_key, String.t()}
          | {:invalid_type, String.t(), expected :: String.t(), got :: term()}
          | {:invalid_value, String.t(), term()}

  @doc """
  Convert a decoded TOML map into a validated skill struct.

  The TOML parser is expected to decode keys as strings.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, decode_error}
  def from_map(map) when is_map(map) do
    with {:ok, name} <- required_string(map, "name"),
         {:ok, description} <- required_string(map, "description"),
         {:ok, model} <- required_string(map, "model"),
         {:ok, tools} <- required_string_list(map, "tools"),
         {:ok, system_prompt} <- required_string(map, "system_prompt"),
         {:ok, response_format} <- optional_map(map, "response_format") do
      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         model: model,
         tools: tools,
         system_prompt: system_prompt,
         response_format: response_format
       }}
    end
  end

  defp required_string(map, key) do
    case Map.fetch(map, key) do
      :error -> {:error, {:missing_key, key}}
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      {:ok, value} when is_binary(value) -> {:error, {:invalid_value, key, value}}
      {:ok, value} -> {:error, {:invalid_type, key, "string", value}}
    end
  end

  defp required_string_list(map, key) do
    case Map.fetch(map, key) do
      :error ->
        {:error, {:missing_key, key}}

      {:ok, list} when is_list(list) ->
        list
        |> Enum.reject(&(not is_binary(&1)))
        |> case do
          [] -> {:error, {:invalid_value, key, list}}
          strings -> {:ok, strings}
        end

      {:ok, value} ->
        {:error, {:invalid_type, key, "array of strings", value}}
    end
  end

  defp optional_map(map, key) do
    case Map.fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_type, key, "table/map", value}}
    end
  end
end
