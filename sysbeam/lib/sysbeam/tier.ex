defmodule Sysbeam.Tier do
  @moduledoc """
  Runs the next tier as a port and respawns it when it exits. The child's
  stdin is this port's pipe, so if this BEAM dies the child sees EOF and halts
  (Sysbeam.ParentWatch), taking its own subtree with it.
  """
  use GenServer

  @sysbeam "/sbin/sysbeam"
  @backoff_ms 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    role = Keyword.fetch!(opts, :role)
    args = [role | List.wrap(opts[:index])]
    {:ok, %{args: args, port: open(args)}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port, args: args} = state) do
    Sysbeam.log(hd(args), "#{Enum.join(args, " ")} exited #{status}, respawning in #{@backoff_ms}ms")
    Process.send_after(self(), :respawn, @backoff_ms)
    {:noreply, %{state | port: nil}}
  end

  def handle_info(:respawn, %{args: args} = state), do: {:noreply, %{state | port: open(args)}}
  def handle_info(_, state), do: {:noreply, state}

  # ponytail: fixed backoff, no crash-loop detection
  defp open(args), do: Port.open({:spawn_executable, @sysbeam}, [:exit_status, args: args])
end

defmodule Sysbeam.ParentWatch do
  @moduledoc "Halt when stdin hits EOF: the parent BEAM's port pipe closed, so the parent is gone."
  use Task, restart: :permanent

  def start_link(_), do: Task.start_link(__MODULE__, :run, [])

  def run do
    IO.read(:stdio, :eof)
    Sysbeam.log("main", "parent gone (stdin EOF), halting")
    System.halt(0)
  end
end
