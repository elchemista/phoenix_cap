defmodule PhoenixCap.Challenge do
  @moduledoc """
  Cap-compatible proof-of-work challenge generation and redemption.

  This module implements the compact challenge protocol used by the Cap widget:
  the server stores `{c, s, d}` plus an opaque challenge token, while the widget
  derives the actual `{salt, target}` pairs locally from that token.
  """

  import Bitwise

  alias PhoenixCap.Store.ETS
  alias PhoenixCap.Verification

  @challenge_count 50
  @challenge_size 32
  @challenge_difficulty 4
  @challenge_ttl_ms 10 * 60 * 1000
  @challenge %{c: @challenge_count, s: @challenge_size, d: @challenge_difficulty}

  @typedoc "Compact Cap challenge parameters sent to the widget."
  @type challenge :: %{
          required(:c) => pos_integer(),
          required(:s) => pos_integer(),
          required(:d) => pos_integer()
        }

  @typedoc "Stored challenge data with an absolute Unix millisecond expiry."
  @type stored_challenge :: %{
          required(:challenge) => challenge(),
          required(:expires) => pos_integer()
        }

  @typedoc "Challenge response shape expected by the Cap widget."
  @type response :: %{
          required(:challenge) => challenge(),
          required(:token) => binary(),
          required(:expires) => pos_integer()
        }

  @typedoc "Redeem request body decoded from JSON."
  @type redeem_params :: %{required(binary()) => term()}

  @doc """
  Creates and stores a single-use Cap challenge.

  The returned JSON-compatible map matches the upstream `@cap.js/server`
  `createChallenge` response: `%{challenge: %{c, s, d}, token, expires}`.
  """
  @spec create() :: response()
  def create do
    token = random_hex(25)
    expires = now_ms() + @challenge_ttl_ms

    :ok = ETS.put_challenge(token, %{challenge: @challenge, expires: expires})

    %{challenge: @challenge, token: token, expires: expires}
  end

  @doc """
  Redeems a solved challenge and issues a one-time verification token.

  The challenge is consumed exactly once, matching Cap's server behavior: once a
  syntactically valid redeem attempt reaches stored challenge lookup, retrying
  the same challenge token fails.
  """
  @spec redeem(Plug.Conn.t(), redeem_params()) :: {:ok, map()} | {:error, binary()}
  def redeem(conn, %{"token" => token, "solutions" => solutions})
      when is_binary(token) and is_list(solutions) do
    with :ok <- validate_solution_body(solutions),
         {:ok, %{challenge: challenge}} <- ETS.take_challenge(token),
         :ok <- verify_solutions(token, challenge, solutions),
         {:ok, verify_token, expires} <- Verification.issue(conn) do
      {:ok, %{success: true, token: verify_token, expires: expires}}
    else
      {:error, :not_found} -> {:error, "Challenge invalid or expired"}
      {:error, :expired} -> {:error, "Challenge invalid or expired"}
      {:error, :invalid_solution} -> {:error, "Invalid solution"}
      {:error, :missing_token_module} -> {:error, "Token module not configured"}
      {:error, :invalid_body} -> {:error, "Invalid body"}
      {:error, _reason} -> {:error, "Invalid body"}
    end
  end

  def redeem(_conn, _params), do: {:error, "Invalid body"}

  @doc """
  Verifies all nonce solutions for a compact Cap challenge.
  """
  @spec verify_solutions(binary(), challenge(), [integer()]) :: :ok | {:error, :invalid_solution}
  def verify_solutions(token, %{c: count, s: size, d: difficulty}, solutions)
      when is_binary(token) and is_integer(count) and is_integer(size) and is_integer(difficulty) and
             is_list(solutions) and length(solutions) == count do
    if Enum.all?(Enum.with_index(solutions, 1), &solution_valid?(token, size, difficulty, &1)) do
      :ok
    else
      {:error, :invalid_solution}
    end
  end

  def verify_solutions(_token, _challenge, _solutions), do: {:error, :invalid_solution}

  @doc """
  Verifies one `{salt, target}` challenge pair against a nonce.

  This is useful for parity tests against Cap's WASM solver vectors.
  """
  @spec verify_challenge_pair(binary(), binary(), integer()) :: boolean()
  def verify_challenge_pair(salt, target, nonce)
      when is_binary(salt) and is_binary(target) and is_integer(nonce) do
    :sha256
    |> :crypto.hash(salt <> Integer.to_string(nonce))
    |> Base.encode16(case: :lower)
    |> String.starts_with?(target)
  end

  def verify_challenge_pair(_salt, _target, _nonce), do: false

  @doc """
  Generates deterministic hex output compatible with Cap's widget PRNG.
  """
  @spec prng(binary(), non_neg_integer()) :: binary()
  def prng(seed, length) when is_binary(seed) and is_integer(length) and length >= 0 do
    seed
    |> fnv1a()
    |> prng_chunks("", length)
    |> binary_part(0, length)
  end

  defp solution_valid?(token, size, difficulty, {nonce, index}) when is_integer(nonce) do
    salt = prng("#{token}#{index}", size)
    target = prng("#{token}#{index}d", difficulty)

    verify_challenge_pair(salt, target, nonce)
  end

  defp solution_valid?(_token, _size, _difficulty, _solution), do: false

  defp validate_solution_body([]), do: :ok

  defp validate_solution_body([solution | rest]) when is_integer(solution) do
    validate_solution_body(rest)
  end

  defp validate_solution_body(_solutions), do: {:error, :invalid_body}

  defp prng_chunks(_state, result, length) when byte_size(result) >= length, do: result

  # Cap uses FNV-1a for the seed and a xorshift32 stream for deterministic
  # salt/target derivation. Keep the unsigned 32-bit truncation points explicit.
  defp prng_chunks(state, result, length) do
    next_state =
      state
      |> bxor(u32(state <<< 13))
      |> u32()
      |> then(fn value -> bxor(value, value >>> 17) end)
      |> u32()
      |> then(fn value -> bxor(value, u32(value <<< 5)) end)
      |> u32()

    chunk =
      next_state
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(8, "0")

    prng_chunks(next_state, result <> chunk, length)
  end

  defp fnv1a(seed) do
    seed
    |> String.to_charlist()
    |> Enum.reduce(2_166_136_261, &fnv1a_step/2)
  end

  defp fnv1a_step(char, hash) do
    value = bxor(hash, char)

    (value +
       u32(value <<< 1) +
       u32(value <<< 4) +
       u32(value <<< 7) +
       u32(value <<< 8) +
       u32(value <<< 24))
    |> u32()
  end

  defp random_hex(bytes) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp u32(value), do: value &&& 0xFFFF_FFFF
end
