defmodule SafeJson do
  @moduledoc """
  Thin wrapper around a JSON library.

  This module is a single chokepoint for JSON serialization in the app. It:

  * Sanitizes binaries before encoding to avoid errors on invalid UTF-8.
  * Translates backend-specific encode/decode errors into stable, backend-agnostic
    error tuples.

  ## Struct serialization

  Structs that need JSON encoding should implement the `SafeJson.Serialize`
  protocol rather than using `@derive {Jason.Encoder, ...}`. This keeps JSON
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

  @type decode_error :: {:invalid_json, String.t()}
  @type encode_error :: {:invalid_json, String.t()}

  @spec encode(term) :: {:ok, String.t()} | {:error, encode_error}
  def encode(term) do
    Jason.encode(sanitize(term))
    |> case do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:invalid_json, error_message(reason)}}
    end
  rescue
    e -> {:error, {:invalid_json, error_message(e)}}
  end

  @spec encode(term, keyword) :: {:ok, String.t()} | {:error, encode_error}
  def encode(term, opts) do
    Jason.encode(sanitize(term), opts)
    |> case do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:invalid_json, error_message(reason)}}
    end
  rescue
    e -> {:error, {:invalid_json, error_message(e)}}
  end

  @spec encode!(term) :: String.t()
  def encode!(term) do
    case encode(term) do
      {:ok, json} ->
        json

      {:error, {:invalid_json, reason}} ->
        raise("JSON encode failed: #{reason}")
    end
  end

  @spec encode!(term, keyword) :: String.t()
  def encode!(term, opts) do
    case encode(term, opts) do
      {:ok, json} ->
        json

      {:error, {:invalid_json, reason}} ->
        raise("JSON encode failed: #{reason}")
    end
  end

  # ---------------------------------------------------------------------------
  # Decode
  # ---------------------------------------------------------------------------

  @spec decode(binary) :: {:ok, term} | {:error, decode_error}
  def decode(input) do
    Jason.decode(input)
    |> case do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, error_message(reason)}}
    end
  rescue
    e -> {:error, {:invalid_json, error_message(e)}}
  end

  @spec decode(binary, keyword) :: {:ok, term} | {:error, decode_error}
  def decode(input, opts) do
    Jason.decode(input, opts)
    |> case do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, error_message(reason)}}
    end
  rescue
    e -> {:error, {:invalid_json, error_message(e)}}
  end

  @spec decode!(binary) :: term
  def decode!(input) do
    case decode(input) do
      {:ok, decoded} ->
        decoded

      {:error, {:invalid_json, reason}} ->
        raise("JSON decode failed: #{reason}")
    end
  end

  @spec decode!(binary, keyword) :: term
  def decode!(input, opts) do
    case decode(input, opts) do
      {:ok, decoded} ->
        decoded

      {:error, {:invalid_json, reason}} ->
        raise("JSON decode failed: #{reason}")
    end
  end

  # ---------------------------------------------------------------------------
  # Lenient decode
  #
  # LLM responses nominally constrained by response_format can still arrive
  # wrapped in markdown code fences or prefixed with prose. These helpers strip
  # that noise before decoding, making structured-output parsing more robust.
  # ---------------------------------------------------------------------------

  @doc """
  Like `decode/1`, but strips markdown code fences and leading prose before
  decoding. Use when parsing LLM responses that should be JSON but may be
  wrapped in fences or prefixed with text.
  """
  @spec decode_lenient(binary | nil) :: {:ok, term} | {:error, decode_error}
  def decode_lenient(nil), do: {:error, {:invalid_json, "nil input"}}

  def decode_lenient(input) when is_binary(input) do
    input
    |> strip_code_fences()
    |> extract_json_object()
    |> decode()
  end

  @doc """
  Like `decode/2`, but strips markdown code fences and leading prose before
  decoding.
  """
  @spec decode_lenient(binary | nil, keyword) :: {:ok, term} | {:error, decode_error}
  def decode_lenient(nil, _opts), do: {:error, {:invalid_json, "nil input"}}

  def decode_lenient(input, opts) when is_binary(input) do
    input
    |> strip_code_fences()
    |> extract_json_object()
    |> decode(opts)
  end

  # Remove wrapping ```json ... ``` or ``` ... ``` fences.
  defp strip_code_fences(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```json\s*/i, "")
    |> String.replace(~r/^```\s*/, "")
    |> String.replace(~r/\s*```$/, "")
  end

  # Drop any prefix before the first '{' so prose preamble doesn't break parsing.
  defp extract_json_object(text) do
    case String.split(text, "{", parts: 2) do
      [_, rest] -> "{" <> rest
      _ -> text
    end
  end

  defp error_message(reason) do
    try do
      Exception.message(reason)
    rescue
      _ -> to_string(reason)
    end
  end

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
