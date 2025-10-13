defmodule Services.Approvals.Gate do
  @moduledoc """
  Minimal in-memory approvals gate for sensitive "finalize" steps (M4).

  Provides a tiny API:
    - `require/2` requests approval (`:approved` or `{:pending, ref}`)
    - `approve/1` and `deny/2` control a pending reference
    - `status/1` and `list/0` allow inspection

  Policy:
    - Reads `"approvals" -> "mcp_auth_finalize"` from `Settings`.
    - Default: `"auto_approve"`. `"require_approval"` returns pending.

  Usage:
    - Insert a single checkpoint before writing sensitive data (e.g., tokens).
    - Return pending + `ref` and instruct operators to use the CLI to approve.

  Introduced: M4.
  """

  use Agent

  @type ref :: String.t()
  @type status :: :pending | :approved | {:denied, String.t()}

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Require approval for a resource. Returns :approved immediately when policy is
  auto_approve; otherwise returns {:pending, ref}.
  """
  @spec require(resource :: term(), opts :: keyword()) :: :approved | {:pending, ref}
  def require(resource, _opts \\ []) do
    if auto_approve?(resource) do
      :approved
    else
      ref = gen_ref()
      now = System.os_time(:second)

      Agent.update(__MODULE__, fn m ->
        Map.put(m, ref, %{resource: resource, status: :pending, created_at: now})
      end)

      {:pending, ref}
    end
  end

  @doc """
  Approve a pending reference.
  """
  @spec approve(ref) :: :ok | {:error, :not_found}
  def approve(ref), do: update(ref, fn m -> %{m | status: :approved} end)

  @doc """
  Deny a pending reference with a reason.
  """
  @spec deny(ref, String.t()) :: :ok | {:error, :not_found}
  def deny(ref, reason), do: update(ref, fn m -> %{m | status: {:denied, reason}} end)

  @doc """
  Get status of a reference.
  """
  @spec status(ref) :: status | {:error, :not_found}
  def status(ref) do
    Agent.get(__MODULE__, fn m ->
      case Map.get(m, ref) do
        nil -> {:error, :not_found}
        %{status: s} -> s
      end
    end)
  end

  @doc """
  List all current approvals tracked in memory.
  """
  @spec list() :: list(map())
  def list do
    Agent.get(__MODULE__, fn m ->
      Enum.map(m, fn {ref, v} -> Map.put(v, :ref, ref) end)
    end)
  end

  # -- internals --

  defp update(ref, fun) do
    Agent.get_and_update(__MODULE__, fn m ->
      case Map.get(m, ref) do
        nil -> {{:error, :not_found}, m}
        v -> {:ok, Map.put(m, ref, fun.(v))}
      end
    end)
  end

  defp gen_ref, do: "appr-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

  # Default policy is auto_approve; can be overridden in settings.
  # For MVP we only check mcp_auth_finalize policy; everything else auto-approves.
  defp auto_approve?({:mcp, _server, :auth_finalize}) do
    settings = Settings.new()
    approvals = Settings.get(settings, "approvals", %{})

    case Map.get(approvals, "mcp_auth_finalize", "auto_approve") do
      "require_approval" -> false
      _ -> true
    end
  end

  defp auto_approve?(_), do: true
end
