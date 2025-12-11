defmodule Store.Project.Plan do
  @moduledoc """
  Helpers for computing plan paths under the fnord project store.

  Plans are stored as JSON files under the `plans` directory in the project
  store, for example:

      ~/.fnord/projects/<project>/plans/<plan-name>.json

  This module does *not* create directories or files; callers are responsible
  for ensuring that the directory exists before writing.
  """

  @plans_dir "plans"

  @typedoc "Plan structure"
  @type t :: %__MODULE__{
          version: integer(),
          meta: map(),
          design: map() | nil,
          implementation: map() | nil,
          decisions: list(map()),
          work_log: list(map()),
          raw: map() | nil
        }

  defstruct [
    :version,
    :meta,
    :design,
    :implementation,
    :decisions,
    :work_log,
    :raw
  ]

  @doc """
  Returns the directory under the project store where plans are kept.
  """
  @spec plan_dir(Store.Project.t()) :: String.t()
  def plan_dir(%Store.Project{} = project) do
    Path.join(project.store_path, @plans_dir)
  end

  @doc """
  Returns the full path to a plan JSON file for the given plan name.
  """
  @spec plan_path(Store.Project.t(), String.t()) :: String.t()
  def plan_path(%Store.Project{} = project, plan_name) when is_binary(plan_name) do
    project
    |> plan_dir()
    |> Path.join("#{plan_name}.json")
  end

  @doc """
  Normalizes a decoded JSON map into a `Plan.t`.

  This function is tolerant of missing and unknown fields. Unknown top level
  keys are preserved in the `raw` field for potential future use.
  """
  @spec normalize(map()) :: {:ok, t()} | {:error, term()}
  def normalize(%{} = data) do
    version = Map.get(data, "version", 1)

    case version do
      1 -> normalize_v1(data)
      _ -> {:error, :unsupported_version}
    end
  end

  defp normalize_v1(%{} = data) do
    meta = Map.get(data, "meta", %{})
    design = Map.get(data, "design", nil)
    implementation = Map.get(data, "implementation", nil)
    decisions = Map.get(data, "decisions", [])
    work_log = Map.get(data, "work_log", [])

    plan = %__MODULE__{
      version: 1,
      meta: meta,
      design: design,
      implementation: implementation,
      decisions: decisions,
      work_log: work_log,
      raw: data
    }

    {:ok, plan}
  end

  @doc """
  Reads a plan from the given JSON file path.

  Returns `{:ok, Plan.t}` on success or `{:error, reason}` on failure.
  """
  @spec read(String.t()) :: {:ok, t()} | {:error, term()}
  def read(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, data} <- Jason.decode(contents),
         {:ok, plan} <- normalize(data) do
      {:ok, plan}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json_format}
      {:error, _} = err -> err
    end
  end

  @doc """
  Writes the given plan to the given path as JSON.

  This emits only the canonical fields defined by the v1 schema; unknown
  top level keys from `raw` are not preserved.
  """
  @spec write(String.t(), t()) :: :ok | {:error, term()}
  def write(path, %__MODULE__{} = plan) when is_binary(path) do
    data = %{
      "version" => plan.version || 1,
      "meta" => plan.meta || %{},
      "design" => plan.design,
      "implementation" => plan.implementation,
      "decisions" => plan.decisions || [],
      "work_log" => plan.work_log || []
    }

    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    with {:ok, json} <- Jason.encode(data),
         :ok <- File.write(path, json) do
      :ok
    end
  end
end
