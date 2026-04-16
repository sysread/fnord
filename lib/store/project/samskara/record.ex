defmodule Store.Project.Samskara.Record do
  @moduledoc """
  A single samskara record: a minted impression of a user reaction. Records
  live one-per-file in the project's `samskaras/` directory as JSON.
  """

  defstruct [
    :id,
    :minted_at,
    :source_turn_ref,
    :reaction,
    :intensity,
    :gist,
    :lessons,
    :tags,
    :embedding,
    :consolidated_into,
    :superseded,
    :impression?
  ]

  @type reaction ::
          :correction
          | :approval
          | :pivot
          | :frustration
          | :delight
          | :clarification
          | :other

  @type t :: %__MODULE__{
          id: binary,
          minted_at: DateTime.t(),
          source_turn_ref: binary | nil,
          reaction: atom,
          intensity: float,
          gist: binary,
          lessons: [binary],
          tags: [binary],
          embedding: [float],
          consolidated_into: binary | nil,
          superseded: boolean,
          impression?: boolean
        }

  @spec new(keyword | map) :: t
  def new(fields) when is_list(fields), do: new(Map.new(fields))

  def new(fields) when is_map(fields) do
    %__MODULE__{
      id: Map.get(fields, :id) || Uniq.UUID.uuid4(),
      minted_at: Map.get(fields, :minted_at) || DateTime.utc_now(),
      source_turn_ref: Map.get(fields, :source_turn_ref),
      reaction: Map.get(fields, :reaction, :other),
      intensity: Map.get(fields, :intensity, 0.5) |> to_float(),
      gist: Map.get(fields, :gist, ""),
      lessons: Map.get(fields, :lessons, []),
      tags: Map.get(fields, :tags, []),
      embedding: Map.get(fields, :embedding, []),
      consolidated_into: Map.get(fields, :consolidated_into),
      superseded: !!Map.get(fields, :superseded, false),
      impression?: !!Map.get(fields, :impression?, false)
    }
  end

  @spec to_json_map(t) :: map
  def to_json_map(%__MODULE__{} = r) do
    %{
      "id" => r.id,
      "minted_at" => DateTime.to_iso8601(r.minted_at),
      "source_turn_ref" => r.source_turn_ref,
      "reaction" => Atom.to_string(r.reaction),
      "intensity" => r.intensity,
      "gist" => r.gist,
      "lessons" => r.lessons,
      "tags" => r.tags,
      "embedding" => r.embedding,
      "consolidated_into" => r.consolidated_into,
      "superseded" => r.superseded,
      "impression" => r.impression?
    }
  end

  @spec from_json_map(map) :: t
  def from_json_map(%{} = data) do
    new(%{
      id: Map.get(data, "id"),
      minted_at: parse_ts(Map.get(data, "minted_at")),
      source_turn_ref: Map.get(data, "source_turn_ref"),
      reaction: Map.get(data, "reaction", "other") |> to_atom(),
      intensity: Map.get(data, "intensity", 0.5),
      gist: Map.get(data, "gist", ""),
      lessons: Map.get(data, "lessons", []),
      tags: Map.get(data, "tags", []),
      embedding: Map.get(data, "embedding", []),
      consolidated_into: Map.get(data, "consolidated_into"),
      superseded: Map.get(data, "superseded", false),
      impression?: Map.get(data, "impression", false)
    })
  end

  defp parse_ts(nil), do: DateTime.utc_now()

  defp parse_ts(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_ts(%DateTime{} = dt), do: dt

  defp to_atom(value) when is_atom(value), do: value

  defp to_atom(value) when is_binary(value) do
    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> :other
    end
  end

  defp to_atom(_), do: :other

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> f
      :error -> 0.5
    end
  end

  defp to_float(_), do: 0.5
end
