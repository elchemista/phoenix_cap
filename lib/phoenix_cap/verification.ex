defmodule PhoenixCap.Verification do
  @moduledoc false

  alias PhoenixCap.Store.ETS

  @token_ttl_seconds 20 * 60
  @default_token_salt "phoenix-cap-token"

  def issue(conn) do
    expires = now_ms() + @token_ttl_seconds * 1000

    payload = %{
      nonce: random_hex(16),
      solved_at: System.system_time(:second)
    }

    with {:ok, module} <- token_module(),
         {:ok, context} <- token_context(conn),
         token when is_binary(token) <- module.sign(context, token_salt(), payload) do
      :ok = ETS.put_token(hash(token), expires)
      {:ok, token, expires}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :token_sign_failed}
    end
  end

  def verify(_conn, token) when not is_binary(token), do: {:error, :missing_token}

  def verify(conn, token) do
    with {:ok, module} <- token_module(),
         {:ok, context} <- token_context(conn),
         {:ok, _payload} <-
           module.verify(context, token_salt(), token, max_age: @token_ttl_seconds),
         {:ok, _expires} <- ETS.take_token(hash(token)) do
      :ok
    else
      {:error, :not_found} -> {:error, :used_or_unknown}
      {:error, :expired} -> {:error, :expired}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid}
    end
  end

  defp token_module do
    case Application.fetch_env(:phoenix_cap, :token_module) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :missing_token_module}
    end
  end

  defp token_context(%Plug.Conn{} = conn) do
    cond do
      context = Application.get_env(:phoenix_cap, :token_context) ->
        {:ok, context}

      context = conn.private[:phoenix_endpoint] ->
        {:ok, context}

      true ->
        {:ok, conn}
    end
  end

  defp token_salt do
    Application.get_env(:phoenix_cap, :token_salt, @default_token_salt)
  end

  defp hash(token) do
    :sha256
    |> :crypto.hash(token)
    |> Base.encode16(case: :lower)
  end

  defp random_hex(bytes) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp now_ms, do: System.system_time(:millisecond)
end
