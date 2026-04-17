defmodule AI.Agent.SamskaraMinter do
  @moduledoc """
  Two-pass minter. Given a classified reaction, extracts a gist + lessons +
  tags from the turn, embeds the gist, and writes a samskara record to the
  project's store.

  Pass 1 — the classifier upstream has already decided to mint; this module's
  callers supply the verdict. Minter's "pass 1" here is the extraction call.

  Pass 2 — embedding + persistence.
  """

  @behaviour AI.Agent

  @model AI.Model.fast()

  @prompt """
  You are synthesizing a single compact samskara (impression record) from a
  user reaction to a prior assistant response.

  Respond ONLY with a JSON object with exactly these keys:
  - "gist": a single-sentence summary of what the user reacted to and how, in third person.
  - "lessons": an array of 0-3 short, actionable takeaways for the assistant (e.g., "prefer X over Y in this codebase"). Prefer fewer lessons unless the reaction clearly supports more.
  - "tags": an array of 0-5 short tag strings (lowercase, hyphenated).

  Keep gist under 200 characters. Keep each lesson under 140 characters. Keep
  each tag under 24 characters. Do not include any prose outside the JSON.
  """

  alias Store.Project.Samskara
  alias Store.Project.Samskara.Record

  @type mint_opts :: %{
          required(:project) => Store.Project.t(),
          required(:reaction) => atom,
          required(:intensity) => float,
          required(:prev_assistant) => binary,
          required(:user_message) => binary,
          optional(:source_turn_ref) => binary
        }

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, project} <- fetch(opts, :project),
         {:ok, reaction} <- fetch(opts, :reaction),
         {:ok, intensity} <- fetch(opts, :intensity),
         {:ok, prev} <- fetch(opts, :prev_assistant),
         {:ok, curr} <- fetch(opts, :user_message) do
      agent = Map.get(opts, :agent)
      source_turn_ref = Map.get(opts, :source_turn_ref)

      case extract(agent, reaction, prev, curr) do
        {:ok, %{"gist" => gist} = extracted} when is_binary(gist) and gist != "" ->
          lessons = Map.get(extracted, "lessons", []) |> ensure_list_of_binaries()
          tags = Map.get(extracted, "tags", []) |> ensure_list_of_binaries()

          case AI.Samskara.Firing.embed(gist) do
            {:ok, embedding} ->
              record =
                Record.new(%{
                  reaction: reaction,
                  intensity: intensity,
                  gist: gist,
                  lessons: lessons,
                  tags: tags,
                  embedding: embedding,
                  source_turn_ref: source_turn_ref
                })

              case Samskara.write(project, record) do
                {:ok, saved} ->
                  log_mint(saved)
                  {:ok, saved}

                {:error, reason} ->
                  {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, _partial} ->
          {:error, :minter_extraction_incomplete}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Pass 1: extract
  # ---------------------------------------------------------------------------
  defp extract(agent, reaction, prev, curr) do
    messages = [
      AI.Util.system_msg(@prompt),
      AI.Util.user_msg("""
      # Reaction classification
      #{reaction}

      # Previous assistant response
      #{prev}

      # Current user message
      #{curr}
      """)
    ]

    AI.Agent.get_completion(agent,
      model: @model,
      messages: messages
    )
    |> case do
      {:ok, %{response: response}} ->
        case decode_json(response) do
          {:ok, data} when is_map(data) -> {:ok, data}
          _ -> {:error, :minter_invalid_json}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_json(str) do
    str
    |> String.trim()
    |> strip_code_fence()
    |> SafeJson.decode()
  end

  defp strip_code_fence(str) do
    str
    |> String.replace(~r/^```(?:json)?\s*/, "")
    |> String.replace(~r/\s*```$/, "")
  end

  defp ensure_list_of_binaries(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp ensure_list_of_binaries(_), do: []

  defp fetch(opts, key) do
    case Map.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "Missing required argument: #{key}"}
    end
  end

  defp log_mint(%Record{} = record) do
    if Util.Env.looks_truthy?("FNORD_DEBUG_SAMSKARA") do
      UI.debug("samskara:mint", "#{record.id} #{record.reaction} #{record.gist}")
    end

    :ok
  end
end
