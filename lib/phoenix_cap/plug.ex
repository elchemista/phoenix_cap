defmodule PhoenixCap.Plug do
  @moduledoc """
  Minimal Cap-compatible endpoint for Phoenix.

      forward "/cap", PhoenixCap.Plug
  """

  import Plug.Conn

  alias PhoenixCap.Challenge
  alias PhoenixCap.JSON

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", path_info: ["challenge"]} = conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(Challenge.create()))
  end

  def call(%Plug.Conn{method: "POST", path_info: ["redeem"]} = conn, _opts) do
    with {:ok, conn, params} <- read_json(conn),
         {:ok, response} <- Challenge.redeem(conn, params) do
      json(conn, 200, response)
    else
      {:error, message} when is_binary(message) ->
        json(conn, 200, %{success: false, message: message})
    end
  end

  def call(conn, _opts) do
    send_resp(conn, 404, "not found")
  end

  defp read_json(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    case read_body(conn) do
      {:ok, "", conn} ->
        {:ok, conn, %{}}

      {:ok, body, conn} ->
        case JSON.decode(body) do
          {:ok, params} -> {:ok, conn, params}
          {:error, _reason} -> {:error, "Invalid body"}
        end

      {:more, _partial, _conn} ->
        {:error, "Invalid body"}

      {:error, _reason} ->
        {:error, "Invalid body"}
    end
  end

  defp read_json(%Plug.Conn{body_params: params} = conn) when is_map(params) do
    {:ok, conn, params}
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
