defmodule PhoenixCap do
  @moduledoc """
  Tiny Phoenix-native verifier for the Cap widget.
  """

  alias PhoenixCap.Verification

  @doc """
  Verifies and consumes a Cap verification token.
  """
  def verify(conn, token) do
    Verification.verify(conn, token)
  end

  @doc """
  Verifies and consumes a Cap verification token using configured token options.
  """
  def verify(token) do
    Verification.verify(%Plug.Conn{}, token)
  end
end
