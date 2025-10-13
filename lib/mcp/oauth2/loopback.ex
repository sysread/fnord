defmodule MCP.OAuth2.Loopback do
  @moduledoc """
  Minimal loopback HTTP server for OAuth2 Authorization Code callback.

  - Binds to 127.0.0.1 on an ephemeral port
  - Exposes GET /callback to capture `code` and `state`
  - Delegates token exchange to `MCP.OAuth2.Client.handle_callback/4`
  - Persists tokens via `MCP.OAuth2.CredentialsStore`
  - Returns a tiny HTML page and stops itself
  """

  use GenServer
  require Logger

  @type t :: %{
          server_ref: pid(),
          port: non_neg_integer(),
          state: String.t(),
          code_verifier: String.t(),
          cfg: map(),
          server_key: String.t()
        }

  @doc """
  Start the loopback server on 127.0.0.1:0, returning bound port.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Start the server and return `{pid, port}` so the caller can construct the redirect_uri.
  """
  @spec start(map(), String.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, pid(), non_neg_integer()} | {:error, term()}
  def start(cfg, server_key, expected_state, code_verifier, port \\ 0) do
    with {:ok, pid} <-
           start_link(
             cfg: cfg,
             server_key: server_key,
             state: expected_state,
             code_verifier: code_verifier,
             port: port
           ),
         {:ok, port} <- GenServer.call(pid, :get_port) do
      {:ok, pid, port}
    end
  end

  @doc """
  Run the loopback flow until one callback is handled or timeout.
  Returns the token map on success.
  """
  @spec run(
          map(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:ok, map()} | {:error, term()}
  def run(
        cfg,
        base_url,
        server_key,
        expected_state,
        code_verifier,
        port \\ 0,
        timeout_ms \\ 120_000
      ) do
    {:ok, pid} =
      start_link(
        cfg: cfg,
        base_url: base_url,
        server_key: server_key,
        state: expected_state,
        code_verifier: code_verifier,
        port: port
      )

    GenServer.call(pid, {:await, timeout_ms}, timeout_ms + 5_000)
  end

  # GenServer

  @impl true
  def init(opts) do
    cfg = Keyword.fetch!(opts, :cfg)
    base_url = Keyword.fetch!(opts, :base_url)
    server_key = Keyword.fetch!(opts, :server_key)
    expected_state = Keyword.fetch!(opts, :state)
    code_verifier = Keyword.fetch!(opts, :code_verifier)
    port = Keyword.get(opts, :port, 0)

    # Build Plug router with captured state
    {:ok, plug} = build_router(cfg, base_url, server_key, expected_state, code_verifier)

    ref = :"mcp_oauth_loopback_#{System.unique_integer([:monotonic, :positive])}"
    {:ok, _pid} = Plug.Cowboy.http(plug, [], ip: {127, 0, 0, 1}, port: port, ref: ref)

    actual_port =
      case cowboy_port(ref) do
        {:ok, p} -> p
        _ -> 0
      end

    state = %{
      server_ref: ref,
      port: actual_port,
      state: expected_state,
      code_verifier: code_verifier,
      cfg: cfg,
      server_key: server_key,
      result: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:await, timeout_ms}, from, st) do
    # Save caller; will reply on first callback
    {:noreply, Map.put(st, :await, {from, timeout_ms}), timeout_ms}
  end

  @impl true
  def handle_call(:get_port, _from, st) do
    {:reply, {:ok, st.port}, st}
  end

  @impl true
  def handle_info({:callback_result, result}, %{await: {from, _}} = st) do
    reply =
      case result do
        {:ok, token_map} -> {:ok, token_map}
        {:error, e} -> {:error, e}
      end

    GenServer.reply(from, reply)
    # Keep GenServer alive - escript will exit and clean up naturally
    # This ensures HTTP response has time to be fully sent to browser
    {:noreply, Map.put(st, :result, result)}
  end

  @impl true
  def handle_info(:timeout, st) do
    if st[:await] do
      GenServer.reply(elem(st.await, 0), {:error, :timeout})
    end

    # Don't explicitly shut down - let the escript process exit handle cleanup
    {:stop, :timeout, st}
  end

  defp cowboy_port(ref) do
    case :ranch.get_addr(ref) do
      {_, port} when is_integer(port) ->
        {:ok, port}

      {:local, _socket} ->
        {:error, :local_socket}

      other ->
        {:error, other}
    end
  end

  defp build_router(cfg, base_url, server_key, expected_state, code_verifier) do
    parent = self()

    mod = Module.concat(__MODULE__, :"Router_#{System.unique_integer([:monotonic, :positive])}")

    # Define the router module using defmodule at runtime
    contents =
      quote do
        use Plug.Router
        plug(:match)
        plug(:fetch_query_params)
        plug(:dispatch)

        get "/callback" do
          params = var!(conn).params

          case MCP.OAuth2.Client.handle_callback(
                 unquote(Macro.escape(cfg)),
                 params,
                 unquote(expected_state),
                 unquote(code_verifier)
               ) do
            {:ok, token_map} ->
              case Services.Approvals.Gate.require(
                     {:mcp, unquote(server_key), :auth_finalize},
                     []
                   ) do
                :approved ->
                  :ok =
                    MCP.OAuth2.CredentialsStore.write(unquote(server_key), %{
                      "access_token" => token_map.access_token,
                      "refresh_token" => Map.get(token_map, :refresh_token),
                      "token_type" => token_map.token_type,
                      "expires_at" => token_map.expires_at,
                      "scope" => Map.get(token_map, :scope)
                    })

                  send(unquote(parent), {:callback_result, {:ok, token_map}})
                  send_resp(var!(conn), 200, success_html(unquote(server_key), unquote(base_url)))

                {:pending, ref} ->
                  send(unquote(parent), {:callback_result, {:error, :approval_pending}})
                  send_resp(var!(conn), 202, "Approval pending; ref=" <> ref)
              end

            {:error, e} ->
              send(unquote(parent), {:callback_result, {:error, e}})
              send_resp(var!(conn), 400, failure_html())
          end
        end

        match _ do
          send_resp(var!(conn), 404, "Not Found")
        end

        defp success_html(server_name, base_url) do
          """
          <html>
          <head>
            <meta charset="UTF-8">
            <title>Authentication Complete</title>
            <style>
              body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                max-width: 600px;
                margin: 100px auto;
                padding: 20px;
                text-align: center;
              }
              h3 { color: #2d3748; }
              .details {
                color: #4a5568;
                margin: 20px 0;
                font-size: 0.95em;
              }
            </style>
          </head>
          <body>
            <h3>Authentication complete</h3>
            <div class="details">
              <p><strong>fnord</strong> successfully authenticated</p>
              <p><strong>#{server_name}</strong> at #{base_url}</p>
            </div>
            <p>You can close this tab.</p>
          </body>
          </html>
          """
        end

        defp failure_html do
          "<html><body><h3>Authentication failed</h3><p>Please return to the app.</p></body></html>"
        end
      end

    Module.create(mod, contents, Macro.Env.location(__ENV__))

    {:ok, mod}
  end
end
