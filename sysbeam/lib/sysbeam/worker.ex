defmodule Sysbeam.Worker.Tree do
  @moduledoc """
  One of the worker's four supervision trees: devices, people, programs,
  networks. Placeholder: a named process that holds. The console is not a
  tree's job any more; sbexec puts worker 0's own IEx on ttyS0.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: :"tree_#{opts[:name]}")

  @impl true
  def init(opts) do
    Sysbeam.log("worker", "  supervisor:#{opts[:name]} running (pid #{inspect(self())})")
    {:ok, opts}
  end
end
