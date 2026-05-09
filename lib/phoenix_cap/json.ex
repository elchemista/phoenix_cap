defmodule PhoenixCap.JSON do
  @moduledoc false

  def encode!(term) do
    json_library().encode!(term)
  end

  def decode(term) do
    json_library().decode(term)
  end

  defp json_library do
    Application.fetch_env!(:phoenix_cap, :json_library)
  end
end
