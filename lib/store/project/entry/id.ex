defmodule Store.Project.Entry.ID do
  @prefix_r "r1-"
  @prefix_h "h1-"
  @max_len 240

  @spec to_key(String.t()) :: String.t()
  def to_key(rel_path) do
    reversible = @prefix_r <> Base.url_encode64(rel_path, padding: false)

    if byte_size(reversible) <= @max_len do
      reversible
    else
      @prefix_h <> sha256(rel_path)
    end
  end

  @spec from_key(String.t()) :: {:ok, String.t()} | :error
  def from_key(key) do
    cond do
      String.starts_with?(key, @prefix_r) ->
        encoded = String.slice(key, byte_size(@prefix_r)..-1//1)

        case Base.url_decode64(encoded, padding: false) do
          {:ok, rp} -> {:ok, rp}
          :error -> :error
        end

      true ->
        :error
    end
  end

  # Compute SHA-256 hash and encode as lowercase hex
  defp sha256(data) do
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end
end
