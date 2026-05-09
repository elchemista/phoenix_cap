defmodule PhoenixCap.Store.ETS do
  @moduledoc false

  use GenServer

  @challenges :phoenix_cap_challenges
  @tokens :phoenix_cap_tokens
  @cleanup_interval_ms 5 * 60 * 1000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    new_table(@challenges)
    new_table(@tokens)
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    delete_expired(@challenges)
    delete_expired(@tokens)
    schedule_cleanup()

    {:noreply, state}
  end

  def put_challenge(token, data) do
    :ets.insert(@challenges, {token, data})
    :ok
  end

  def take_challenge(token) do
    take_unexpired(@challenges, token)
  end

  def put_token(token_hash, expires_ms) do
    :ets.insert(@tokens, {token_hash, expires_ms})
    :ok
  end

  def take_token(token_hash) do
    take_unexpired(@tokens, token_hash)
  end

  def reset do
    :ets.delete_all_objects(@challenges)
    :ets.delete_all_objects(@tokens)
    :ok
  end

  def cleanup do
    delete_expired(@challenges)
    delete_expired(@tokens)
    :ok
  end

  defp take_unexpired(table, key) do
    case :ets.take(table, key) do
      [{^key, data}] ->
        if expires_at(data) > System.system_time(:millisecond) do
          {:ok, data}
        else
          {:error, :expired}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp expires_at(%{expires: expires}), do: expires
  defp expires_at(expires) when is_integer(expires), do: expires

  defp new_table(table) do
    :ets.new(table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
  rescue
    ArgumentError -> table
  end

  defp delete_expired(table) do
    now = System.system_time(:millisecond)

    table
    |> :ets.tab2list()
    |> Enum.each(fn {key, data} ->
      if expires_at(data) <= now do
        :ets.delete(table, key)
      end
    end)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
