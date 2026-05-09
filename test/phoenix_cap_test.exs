defmodule PhoenixCap.TestRouter do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  forward("/cap", to: PhoenixCap.Plug)
end

defmodule PhoenixCap.TestJSON do
  defdelegate encode!(term), to: JSON
  defdelegate decode(term), to: JSON
end

defmodule PhoenixCap.TestToken do
  @behaviour PhoenixCap.Token

  def sign(_context, _salt, payload) do
    "custom:" <> Base.url_encode64(:erlang.term_to_binary(payload), padding: false)
  end

  def verify(_context, _salt, "custom:" <> encoded, _opts) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, binary} -> {:ok, :erlang.binary_to_term(binary)}
      :error -> {:error, :invalid}
    end
  end

  def verify(_context, _salt, _token, _opts), do: {:error, :invalid}
end

defmodule PhoenixCapTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias PhoenixCap.Challenge
  alias PhoenixCap.Store.ETS

  @opts PhoenixCap.TestRouter.init([])

  setup do
    Application.put_env(:phoenix_cap, :json_library, JSON)
    Application.put_env(:phoenix_cap, :token_module, PhoenixCap.TestToken)
    Application.put_env(:phoenix_cap, :token_context, :test_context)
    ETS.reset()
    :ok
  end

  test "prng matches Cap's JavaScript implementation" do
    assert Challenge.prng("abc", 32) == "0bb9adb8ffd8e55f8d1de826333f356a"
    assert Challenge.prng("token1", 32) == "8539570754e5fd8b81c9ec01357bd685"
    assert Challenge.prng("token1d", 32) == "4bb7d8dfa52071a9c9b580434e064f3d"
  end

  test "solution verification matches Cap's JavaScript challenge vectors" do
    token = "0123456789abcdef0123456789abcdef0123456789abcdef01"
    challenge = %{c: 5, s: 32, d: 3}

    assert Challenge.prng("#{token}1", 32) == "2b5c4ca2fbc3e5066b0fb0573da6c475"
    assert Challenge.prng("#{token}1d", 3) == "b94"
    assert Challenge.verify_solutions(token, challenge, [4146, 1619, 11_542, 957, 3638]) == :ok
  end

  test "Cap wasm odd-difficulty challenge vector verifies" do
    salt = "02679e6558"
    target = "eeffc"
    nonce = solve_one(salt, target, 0)

    assert Challenge.verify_challenge_pair(salt, target, nonce)
  end

  test "Cap wasm challenge vectors verify after solving" do
    vectors = [
      ["e455cea65e98bc3c36287f43769da211", "dceb"],
      ["fb8d25f6abac5aa9b6360051f37e010b", "93f1"],
      ["91ef47db578fbeb2565d3f9c82bb7960", "3698"],
      ["b7ad7667486a691cda8ef297098f64a7", "d72a"],
      ["1aca3fb7cef7a2be0dee563ed4136758", "3b58"]
    ]

    for [salt, target] <- vectors do
      assert Challenge.verify_challenge_pair(salt, target, solve_one(salt, target, 0))
    end
  end

  test "forwarded plug creates a widget-compatible challenge" do
    conn = dispatch(conn(:post, "/cap/challenge"))

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"

    assert %{
             "challenge" => %{"c" => 50, "s" => 32, "d" => 4},
             "token" => token,
             "expires" => expires
           } = JSON.decode!(conn.resp_body)

    assert is_binary(token)
    assert is_integer(expires)
  end

  test "challenge token and expiry match Cap server defaults" do
    before_request = System.system_time(:millisecond)
    conn = dispatch(conn(:post, "/cap/challenge"))
    after_request = System.system_time(:millisecond)

    assert %{"token" => token, "expires" => expires} = JSON.decode!(conn.resp_body)
    assert String.length(token) == 50
    assert token =~ ~r/^[0-9a-f]+$/
    assert expires >= before_request + 600_000
    assert expires <= after_request + 600_000
  end

  test "challenge response does not include standalone-only instrumentation by default" do
    conn = dispatch(conn(:post, "/cap/challenge"))

    refute Map.has_key?(JSON.decode!(conn.resp_body), "instrumentation")
  end

  test "plug uses configured JSON library" do
    Application.put_env(:phoenix_cap, :json_library, PhoenixCap.TestJSON)

    conn = dispatch(conn(:post, "/cap/challenge"))

    assert %{"challenge" => %{"c" => 50}} = JSON.decode!(conn.resp_body)
  end

  test "valid proof-of-work redeems and verifies once" do
    challenge = create_challenge()
    solutions = solve(challenge)

    redeem_conn =
      :post
      |> conn("/cap/redeem", JSON.encode!(%{token: challenge["token"], solutions: solutions}))
      |> put_req_header("content-type", "application/json")
      |> dispatch()

    assert redeem_conn.status == 200

    assert %{"success" => true, "token" => verify_token, "expires" => expires} =
             JSON.decode!(redeem_conn.resp_body)

    assert is_integer(expires)

    assert PhoenixCap.verify(redeem_conn, verify_token) == :ok
    assert PhoenixCap.verify(redeem_conn, verify_token) == {:error, :used_or_unknown}
  end

  test "redeem rejects missing token" do
    conn =
      :post
      |> conn("/cap/redeem", JSON.encode!(%{solutions: []}))
      |> put_req_header("content-type", "application/json")
      |> dispatch()

    assert %{"success" => false, "message" => "Invalid body"} = JSON.decode!(conn.resp_body)
  end

  test "redeem rejects missing solutions" do
    conn =
      :post
      |> conn("/cap/redeem", JSON.encode!(%{token: "abc"}))
      |> put_req_header("content-type", "application/json")
      |> dispatch()

    assert %{"success" => false, "message" => "Invalid body"} = JSON.decode!(conn.resp_body)
  end

  test "redeem rejects non-list solutions" do
    conn =
      :post
      |> conn("/cap/redeem", JSON.encode!(%{token: "abc", solutions: "nope"}))
      |> put_req_header("content-type", "application/json")
      |> dispatch()

    assert %{"success" => false, "message" => "Invalid body"} = JSON.decode!(conn.resp_body)
  end

  test "redeem rejects non-integer solution values as invalid body" do
    challenge = create_challenge()

    conn =
      :post
      |> conn("/cap/redeem", JSON.encode!(%{token: challenge["token"], solutions: ["bad"]}))
      |> put_req_header("content-type", "application/json")
      |> dispatch()

    assert %{"success" => false, "message" => "Invalid body"} = JSON.decode!(conn.resp_body)
  end

  test "redeem rejects too few solutions" do
    challenge = create_challenge()

    conn =
      :post
      |> conn("/cap/redeem", JSON.encode!(%{token: challenge["token"], solutions: []}))
      |> put_req_header("content-type", "application/json")
      |> dispatch()

    assert %{"success" => false, "message" => "Invalid solution"} = JSON.decode!(conn.resp_body)
  end

  test "redeem rejects too many solutions" do
    challenge = create_challenge()
    solutions = solve(challenge) ++ [0]

    conn =
      :post
      |> conn("/cap/redeem", JSON.encode!(%{token: challenge["token"], solutions: solutions}))
      |> put_req_header("content-type", "application/json")
      |> dispatch()

    assert %{"success" => false, "message" => "Invalid solution"} = JSON.decode!(conn.resp_body)
  end

  test "redeem rejects unknown challenge token" do
    conn =
      :post
      |> conn("/cap/redeem", JSON.encode!(%{token: "missing", solutions: []}))
      |> put_req_header("content-type", "application/json")
      |> dispatch()

    assert %{"success" => false, "message" => "Challenge invalid or expired"} =
             JSON.decode!(conn.resp_body)
  end

  test "redeem rejects malformed JSON" do
    conn =
      :post
      |> conn("/cap/redeem", "{")
      |> put_req_header("content-type", "application/json")
      |> dispatch()

    assert %{"success" => false, "message" => "Invalid body"} = JSON.decode!(conn.resp_body)
  end

  test "redeem rejects empty body" do
    conn = dispatch(conn(:post, "/cap/redeem"))

    assert %{"success" => false, "message" => "Invalid body"} = JSON.decode!(conn.resp_body)
  end

  test "verify token can use configured token context without a conn" do
    challenge = create_challenge()
    solutions = solve(challenge)

    redeem_conn =
      :post
      |> conn("/cap/redeem", JSON.encode!(%{token: challenge["token"], solutions: solutions}))
      |> put_req_header("content-type", "application/json")
      |> dispatch()

    assert %{"success" => true, "token" => verify_token} = JSON.decode!(redeem_conn.resp_body)
    assert PhoenixCap.verify(verify_token) == :ok
  end

  test "custom token module can be configured" do
    challenge = create_challenge()
    solutions = solve(challenge)

    redeem_conn =
      :post
      |> conn("/cap/redeem", JSON.encode!(%{token: challenge["token"], solutions: solutions}))
      |> put_req_header("content-type", "application/json")
      |> dispatch()

    assert %{"success" => true, "token" => "custom:" <> _ = token} =
             JSON.decode!(redeem_conn.resp_body)

    assert PhoenixCap.verify(redeem_conn, token) == :ok
  end

  test "redeem fails clearly when token module is not configured" do
    Application.delete_env(:phoenix_cap, :token_module)
    challenge = create_challenge()
    solutions = solve(challenge)

    conn =
      :post
      |> conn("/cap/redeem", JSON.encode!(%{token: challenge["token"], solutions: solutions}))
      |> put_req_header("content-type", "application/json")
      |> dispatch()

    assert %{"success" => false, "message" => "Token module not configured"} =
             JSON.decode!(conn.resp_body)
  end

  test "redeem accepts body params parsed by an upstream parser" do
    challenge = create_challenge()
    solutions = solve(challenge)

    conn =
      :post
      |> conn("/redeem")
      |> Map.put(:path_info, ["redeem"])
      |> Map.put(:body_params, %{"token" => challenge["token"], "solutions" => solutions})
      |> PhoenixCap.Plug.call([])

    assert %{"success" => true, "token" => token} = JSON.decode!(conn.resp_body)
    assert PhoenixCap.verify(conn, token) == :ok
  end

  test "invalid solution fails and consumes the challenge" do
    challenge = create_challenge()
    body = %{token: challenge["token"], solutions: List.duplicate(0, challenge["challenge"]["c"])}

    first_conn =
      :post
      |> conn("/cap/redeem", JSON.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> dispatch()

    assert %{"success" => false, "message" => "Invalid solution"} =
             JSON.decode!(first_conn.resp_body)

    second_conn =
      :post
      |> conn("/cap/redeem", JSON.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> dispatch()

    assert %{"success" => false, "message" => "Challenge invalid or expired"} =
             JSON.decode!(second_conn.resp_body)
  end

  test "malformed and missing tokens fail verification" do
    conn = conn(:post, "/")

    assert PhoenixCap.verify(conn, nil) == {:error, :missing_token}
    assert match?({:error, _reason}, PhoenixCap.verify(conn, "not-a-real-token"))
  end

  test "expired challenge and token entries are rejected" do
    ETS.put_challenge("expired-challenge", %{
      challenge: %{c: 1, s: 32, d: 4},
      expires: System.system_time(:millisecond) - 1
    })

    assert Challenge.redeem(conn(:post, "/"), %{
             "token" => "expired-challenge",
             "solutions" => [1]
           }) ==
             {:error, "Challenge invalid or expired"}

    token = PhoenixCap.TestToken.sign(conn(:post, "/"), "phoenix-cap-token", %{nonce: "expired"})
    hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
    ETS.put_token(hash, System.system_time(:millisecond) - 1)

    conn = conn(:post, "/")

    assert PhoenixCap.verify(conn, token) == {:error, :expired}
  end

  test "expired entries can be cleaned from ETS" do
    ETS.put_challenge("expired-challenge", %{
      challenge: %{c: 1, s: 32, d: 4},
      expires: System.system_time(:millisecond) - 1
    })

    ETS.put_token("expired-token", System.system_time(:millisecond) - 1)
    assert ETS.cleanup() == :ok

    assert ETS.take_challenge("expired-challenge") == {:error, :not_found}
    assert ETS.take_token("expired-token") == {:error, :not_found}
  end

  test "unknown paths return 404" do
    conn = dispatch(conn(:post, "/cap/other"))

    assert conn.status == 404
  end

  defp create_challenge do
    conn = dispatch(conn(:post, "/cap/challenge"))
    JSON.decode!(conn.resp_body)
  end

  defp dispatch(conn) do
    PhoenixCap.TestRouter.call(conn, @opts)
  end

  defp solve(%{"token" => token, "challenge" => %{"c" => count, "s" => size, "d" => difficulty}}) do
    for index <- 1..count do
      salt = Challenge.prng("#{token}#{index}", size)
      target = Challenge.prng("#{token}#{index}d", difficulty)
      solve_one(salt, target, 0)
    end
  end

  defp solve_one(salt, target, nonce) do
    digest =
      :sha256
      |> :crypto.hash(salt <> Integer.to_string(nonce))
      |> Base.encode16(case: :lower)

    if String.starts_with?(digest, target) do
      nonce
    else
      solve_one(salt, target, nonce + 1)
    end
  end
end
