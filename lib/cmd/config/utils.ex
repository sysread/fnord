defmodule Cmd.Config.Utils do
  @moduledoc false

  @doc """
  Resolve a required parameter out of either opts[key] or the first element of args.

  Returns {:ok, value} if found, or {:error, message} if missing.
  """
  @spec require_key(map(), [any()], atom(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def require_key(opts, args, key, human_name) do
    case opts[key] || List.first(args) do
      nil ->
        {:error,
         "#{human_name} is required. Provide #{human_name} as positional argument or --#{key}."}

      value when is_binary(value) ->
        {:ok, value}
    end
  end
end
