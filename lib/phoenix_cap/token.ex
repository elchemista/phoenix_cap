defmodule PhoenixCap.Token do
  @moduledoc """
  Behaviour for configured verification token modules.

  The configured token module follows the same API shape as `Phoenix.Token`:

      config :phoenix_cap,
        token_module: Phoenix.Token

  Custom token modules should implement `sign/3` and `verify/4` with the same
  argument order.
  """

  @type reason :: atom() | term()

  @callback sign(term(), binary(), term()) :: binary()
  @callback verify(term(), binary(), binary(), keyword()) :: {:ok, term()} | {:error, reason()}
end
