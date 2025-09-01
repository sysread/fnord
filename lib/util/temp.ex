defmodule Util.Temp do
  @spec with_tmp(binary, (binary -> any)) :: any
  def with_tmp(contents, fun) do
    case Briefly.create() do
      {:ok, path} ->
        try do
          case File.write(path, contents) do
            :ok ->
              fun.(path)

            {:error, reason} ->
              {:error, reason}
          end
        after
          # Best-effort cleanup
          _ = File.rm(path)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
