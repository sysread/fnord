defmodule SafeJson do
  @moduledoc """
  Thin wrapper around Jason that sanitizes binaries before encoding to prevent
  `Jason.EncodeError` on invalid UTF-8. The JSON spec (RFC 8259) requires valid
  Unicode strings, but subprocess output, CLI arguments, and external data can
  contain arbitrary bytes. This module is the single chokepoint for all JSON
  serialization in the app, so every path benefits from the same safety net.

  Decode functions delegate directly to Jason today. Routing all decodes through
  this module gives us a seam for future work: migrating to Elixir's stdlib
  `JSON`, normalizing string/atom keys, etc.

  ## Struct serialization

  Structs that need JSON encoding should implement the `SafeJson.Serialize`
  protocol rather than using `@derive {Jason.Encoder, ...}`. This keeps all
  serialization concerns inside SafeJson and avoids leaking the backend library
  into consuming modules.

      defimpl SafeJson.Serialize, for: MyStruct do
        def for_json(%MyStruct{name: name, age: age}) do
          %{name: name, age: age}
        end
      end
  """

  # ---------------------------------------------------------------------------
  # Encode
  # ---------------------------------------------------------------------------

  @spec encode(term) :: {:ok, String.t()} | {:error, Jason.EncodeError.t() | Exception.t()}
  def encode(term), do: term |> sanitize() |> Jason.encode()

  @spec encode(term, keyword) ::
          {:ok, String.t()} | {:error, Jason.EncodeError.t() | Exception.t()}
  def encode(term, opts), do: term |> sanitize() |> Jason.encode(opts)

  @spec encode!(term) :: String.t()
  def encode!(term), do: term |> sanitize() |> Jason.encode!()

  @spec encode!(term, keyword) :: String.t()
  def encode!(term, opts), do: term |> sanitize() |> Jason.encode!(opts)

  # ---------------------------------------------------------------------------
  # Decode - pass-through to Jason for now
  # ---------------------------------------------------------------------------

  defdelegate decode(input), to: Jason
  defdelegate decode(input, opts), to: Jason
  defdelegate decode!(input), to: Jason
  defdelegate decode!(input, opts), to: Jason

  # ---------------------------------------------------------------------------
  # Sanitization
  #
  # Recursively walks the data structure and replaces invalid UTF-8 sequences
  # in every binary value with the Unicode replacement character (U+FFFD).
  #
  # Structs that implement SafeJson.Serialize are converted to plain maps via
  # for_json/1, then sanitized normally. Structs without the protocol are passed
  # through unchanged -- Jason will raise if it can't encode them, which is the
  # desired behavior (forces you to implement the protocol).
  # ---------------------------------------------------------------------------

  defp sanitize(value) when is_binary(value), do: String.replace_invalid(value)

  defp sanitize(value) when is_struct(value) do
    if SafeJson.Serialize.impl_for(value) do
      value |> SafeJson.Serialize.for_json() |> sanitize()
    else
      value
    end
  end

  defp sanitize(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {sanitize(k), sanitize(v)} end)
  end

  defp sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)

  defp sanitize(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&sanitize/1) |> List.to_tuple()
  end

  defp sanitize(value), do: value
end

defprotocol SafeJson.Serialize do
  @moduledoc """
  Protocol for converting structs to JSON-safe plain maps. Implement this
  instead of `@derive {Jason.Encoder, ...}` to keep the JSON backend as an
  internal detail of `SafeJson`.
  """

  @doc """
  Returns a plain map (or other JSON-encodable term) representing the struct.
  The returned value will be recursively sanitized by SafeJson before encoding.
  """
  @spec for_json(t) :: term
  def for_json(value)
end
