defmodule AI.Memory do
  @moduledoc """
  Pure functions for memory matching logic.

  Memories are Bayesian-weighted patterns that fire automatic thoughts based on
  conversation context. Each memory stores a bag-of-words pattern and computes
  match probabilities against accumulated conversation tokens.
  """

  defstruct [
    :id,
    :slug,
    :label,
    :scope,
    :parent_id,
    :children,
    :pattern_tokens,
    :response_template,
    :weight,
    :created_at,
    :last_fired,
    :fire_count,
    :success_count
  ]

  @type scope :: :global | :project

  @type t :: %__MODULE__{
          id: String.t(),
          slug: String.t(),
          label: String.t(),
          scope: scope,
          parent_id: String.t() | nil,
          children: [String.t()],
          pattern_tokens: %{String.t() => non_neg_integer},
          response_template: String.t(),
          weight: float,
          created_at: String.t(),
          last_fired: String.t() | nil,
          fire_count: non_neg_integer,
          success_count: non_neg_integer
        }

  # Configuration constants
  @weight_min 0.1
  @weight_max 10.0
  @response_template_max 500
  @label_max 50

  # Stopwords to remove from token analysis (loaded from NLTK list and stemmed)
  # Applied AFTER stemming in the normalization pipeline
  @stopwords File.read!("data/stopwords.txt")
             |> String.split("\n", trim: true)
             |> Enum.map(&String.trim/1)
             |> Enum.reject(&String.starts_with?(&1, "#"))
             |> Stemmer.stem()
             |> Enum.map(&{&1, true})
             |> Map.new()

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------

  @doc """
  Creates a new memory with default values.
  """
  @spec new(map) :: t
  def new(attrs) do
    slug =
      case attrs[:slug] || attrs[:label] do
        nil -> nil
        label -> generate_slug(label)
      end

    %__MODULE__{
      id: attrs[:id] || Uniq.UUID.uuid7(),
      slug: slug,
      label: attrs[:label],
      scope: attrs[:scope] || :global,
      parent_id: attrs[:parent_id],
      children: attrs[:children] || [],
      pattern_tokens: attrs[:pattern_tokens] || %{},
      response_template: attrs[:response_template],
      weight: attrs[:weight] || 1.0,
      created_at: attrs[:created_at] || DateTime.utc_now() |> DateTime.to_iso8601(),
      last_fired: attrs[:last_fired],
      fire_count: attrs[:fire_count] || 0,
      success_count: attrs[:success_count] || 0
    }
  end

  @doc """
  Validates memory attributes. Returns {:ok, memory} or {:error, reason}.
  """
  @spec validate(t) :: {:ok, t} | {:error, String.t()}
  def validate(memory) do
    cond do
      is_nil(memory.label) or memory.label == "" ->
        {:error, "label is required"}

      String.length(memory.label) > @label_max ->
        {:error, "label exceeds #{@label_max} characters"}

      is_nil(memory.response_template) or memory.response_template == "" ->
        {:error, "response_template is required"}

      String.length(memory.response_template) > @response_template_max ->
        {:error,
         "response_template exceeds #{@response_template_max} characters (keep thoughts brief)"}

      memory.scope not in [:global, :project] ->
        {:error, "scope must be :global or :project"}

      true ->
        {:ok, memory}
    end
  end

  @doc """
  Generates a slug from a label using Django/newspaper style:
  - Lowercase
  - Remove articles (a, an, the)
  - Stem tokens
  - Join with dashes
  - Truncate to 50 characters
  """
  @spec generate_slug(String.t()) :: String.t()
  def generate_slug(label) do
    label
    |> String.downcase()
    |> String.split(~r/\W+/, trim: true)
    |> Enum.reject(&(&1 in ["a", "an", "the"]))
    |> Stemmer.stem()
    |> Enum.join("-")
    |> String.slice(0, @label_max)
  end

  @doc """
  Normalizes text into a bag-of-words with frequencies.
  Pipeline: lowercase -> split -> stem -> remove stopwords -> count frequencies
  """
  @spec normalize_to_tokens(String.t()) :: %{String.t() => non_neg_integer}
  def normalize_to_tokens(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/\W+/, trim: true)
    |> Stemmer.stem()
    |> Enum.reject(&Map.has_key?(@stopwords, &1))
    |> Enum.frequencies()
  end

  @doc """
  Merges new token frequencies into an existing accumulator.
  """
  @spec merge_tokens(%{String.t() => non_neg_integer}, %{String.t() => non_neg_integer}) ::
          %{String.t() => non_neg_integer}
  def merge_tokens(accumulator, new_tokens) do
    Map.merge(accumulator, new_tokens, fn _key, v1, v2 -> v1 + v2 end)
  end

  @doc """
  Sublinearly increases token counts based on context tokens.
  For each {token, ctx_count} in context_tokens with ctx_count > 0:
    - If token not in pattern_tokens: adds token with count equal to ctx_count.
    - If token exists: increment = log10(1.0 + ctx_count), new count = old + increment.
  """
  @spec strengthen_tokens(%{String.t() => number}, %{String.t() => number}) :: %{
          String.t() => number
        }
  def strengthen_tokens(pattern_tokens, context_tokens)
      when is_map(pattern_tokens) and is_map(context_tokens) do
    Enum.reduce(context_tokens, pattern_tokens, fn {token, ctx_count}, acc ->
      if ctx_count > 0 do
        case Map.fetch(acc, token) do
          :error ->
            Map.put(acc, token, ctx_count)

          {:ok, old} ->
            increment = :math.log10(1.0 + ctx_count)
            Map.put(acc, token, old + increment)
        end
      else
        acc
      end
    end)
  end

  @doc """
  Sublinearly decreases token counts based on context tokens.
  For each {token, ctx_count} in context_tokens with ctx_count > 0:
    - If token not in pattern_tokens: ignored.
    - If token exists: decrement = log10(1.0 + ctx_count); new count = old - decrement;
      tokens with new count < 1.0 are removed.
  """
  @spec weaken_tokens(%{String.t() => number}, %{String.t() => number}) :: %{String.t() => number}
  def weaken_tokens(pattern_tokens, context_tokens)
      when is_map(pattern_tokens) and is_map(context_tokens) do
    Enum.reduce(context_tokens, pattern_tokens, fn {token, ctx_count}, acc ->
      if ctx_count > 0 do
        case Map.fetch(acc, token) do
          :error ->
            acc

          {:ok, old} ->
            decrement = :math.log10(1.0 + ctx_count)
            new = old - decrement

            if new < 1.0 do
              Map.delete(acc, token)
            else
              Map.put(acc, token, new)
            end
        end
      else
        acc
      end
    end)
  end

  @doc """
  Trims accumulated tokens to top K by frequency to prevent unbounded growth.
  """
  @spec trim_to_top_k(%{String.t() => non_neg_integer}, non_neg_integer) ::
          %{String.t() => non_neg_integer}
  def trim_to_top_k(tokens, k) do
    tokens
    |> Enum.sort_by(fn {_token, freq} -> -freq end)
    |> Enum.take(k)
    |> Map.new()
  end

  @doc """
  Computes the Bayesian match probability between accumulated conversation tokens
  and a memory's pattern tokens.

  Returns a score between 0.0 and 1.0 representing match confidence.
  Uses log probabilities with Laplace smoothing to avoid underflow.
  """
  @spec compute_match_probability(%{String.t() => non_neg_integer}, %{
          String.t() => non_neg_integer
        }) ::
          float
  def compute_match_probability(accumulated_tokens, pattern_tokens) do
    cond do
      map_size(pattern_tokens) == 0 ->
        0.0

      map_size(accumulated_tokens) == 0 ->
        0.0

      true ->
        vocab_size = map_size(pattern_tokens)
        total_pattern_tokens = Enum.sum(Map.values(pattern_tokens))

        log_prob =
          accumulated_tokens
          |> Enum.map(fn {token, _freq} ->
            # Laplace smoothing: (count + 1) / (total + vocab_size)
            pattern_freq = Map.get(pattern_tokens, token, 0)
            :math.log((pattern_freq + 1) / (total_pattern_tokens + vocab_size))
          end)
          |> Enum.sum()

        # Convert back from log space, normalize to [0, 1]
        # Use min to prevent values > 1.0 from floating point imprecision
        min(1.0, :math.exp(log_prob / max(1, map_size(accumulated_tokens))))
    end
  end

  @doc """
  Computes the final score for a memory by combining match probability and weight.
  Weight is clamped to prevent runaway values.
  """
  @spec compute_score(t, %{String.t() => non_neg_integer}) :: float
  def compute_score(memory, accumulated_tokens) do
    probability = compute_match_probability(accumulated_tokens, memory.pattern_tokens)
    clamped_weight = clamp_weight(memory.weight)
    probability * clamped_weight
  end

  @doc """
  Updates memory pattern tokens by training with new bag-of-words.
  Used for strengthen/weaken operations.
  """
  @spec train(t, String.t(), float) :: t
  def train(memory, match_input, weight_delta) do
    new_tokens = normalize_to_tokens(match_input)
    updated_pattern = merge_tokens(memory.pattern_tokens, new_tokens)
    updated_weight = clamp_weight(memory.weight + weight_delta)

    %{memory | pattern_tokens: updated_pattern, weight: updated_weight}
  end

  @doc """
  Clamps weight to valid range.
  """
  @spec clamp_weight(float) :: float
  def clamp_weight(weight) when weight < @weight_min, do: @weight_min
  def clamp_weight(weight) when weight > @weight_max, do: @weight_max
  def clamp_weight(weight), do: weight

  @spec debug(String.t()) :: :ok
  def debug(msg) do
    System.get_env("FNORD_DEBUG_INTUITION", "")
    |> String.downcase()
    |> String.trim()
    |> case do
      "1" -> true
      "true" -> true
      "yes" -> true
      _ -> false
    end
    |> case do
      true -> UI.debug("[memory]", msg)
      _ -> nil
    end

    :ok
  end

  @doc """
  Returns maximum allowed characters for memory label.
  """
  @spec max_label_chars() :: non_neg_integer()
  def max_label_chars, do: @response_template_max
end
