defmodule Vigil.OAuth.Janitor do
  @moduledoc false
  use GenServer

  @interval 5 * 60 * 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    Vigil.OAuth.Store.sweep_expired(System.system_time(:second))
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
