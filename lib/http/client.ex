defmodule Http.Client do
  @moduledoc """
  The single seam between fnord and the HTTP transport (HTTPoison/hackney).

  Everything that talks to the network - `Http`'s retrying JSON helpers and
  the MCP OAuth/discovery modules that need raw control over timeouts and
  status handling - goes through `impl/0` rather than calling HTTPoison
  directly. That keeps the transport injectable per process tree: tests
  override `:http_client` with a Mox mock (see `Fnord.TestCase`), making the
  network structurally unreachable from the suite, while production resolves
  to this module's passthrough implementation.

  The callback shapes mirror HTTPoison's so call sites keep matching on
  `%HTTPoison.Response{}` / `%HTTPoison.Error{}`; this module deliberately
  adds no behavior of its own.
  """

  @type url :: String.t()
  @type headers :: [{String.t(), String.t()}]
  @type body :: iodata()
  @type opts :: keyword()
  @type result ::
          {:ok,
           HTTPoison.Response.t() | HTTPoison.AsyncResponse.t() | HTTPoison.MaybeRedirect.t()}
          | {:error, HTTPoison.Error.t()}

  @callback get(url, headers, opts) :: result
  @callback post(url, body, headers, opts) :: result
  @callback head(url, headers, opts) :: result

  @behaviour Http.Client

  @impl Http.Client
  def get(url, headers, opts), do: HTTPoison.get(url, headers, opts)

  @impl Http.Client
  def post(url, body, headers, opts), do: HTTPoison.post(url, body, headers, opts)

  @impl Http.Client
  def head(url, headers, opts), do: HTTPoison.head(url, headers, opts)

  @doc """
  Returns the current HTTP transport module. Overridden per process tree via
  the `:http_client` config key for unit testing. See `Fnord.TestCase`.
  """
  @spec impl() :: module()
  def impl() do
    Services.Globals.get_env(:fnord, :http_client) || __MODULE__
  end
end
