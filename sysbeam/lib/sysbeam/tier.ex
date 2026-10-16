defmodule Sysbeam.Tier do
  @moduledoc """
  Runs the next tier as a port and respawns it when it exits. The child's
  stdin is this port's pipe, so if this BEAM dies the child sees EOF and halts
  (Sysbeam.ParentWatch), taking its own subtree with it.

  Options: `role`, `index`; `argv` to replace the default `/sbin/sysbeam role
  index` command (easysec wraps it in capsh); `cgroup`, a cgroup v2 directory
  the child's pid is written into right after each spawn.
  """
  use GenServer

  @sysbeam "/sbin/sysbeam"
  @backoff_ms 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    role = Keyword.fetch!(opts, :role)
    args = [role | List.wrap(opts[:index])]
    state = %{args: args, argv: Keyword.get(opts, :argv, [@sysbeam | args]), cgroup: opts[:cgroup]}
    {:ok, Map.put(state, :port, open(state))}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port, args: args} = state) do
    Sysbeam.log(hd(args), "#{Enum.join(args, " ")} exited #{status}, respawning in #{@backoff_ms}ms")
    Process.send_after(self(), :respawn, @backoff_ms)
    {:noreply, %{state | port: nil}}
  end

  def handle_info(:respawn, state), do: {:noreply, %{state | port: open(state)}}
  def handle_info(_, state), do: {:noreply, state}

  # ponytail: fixed backoff, no crash-loop detection
  defp open(%{argv: [cmd | args], cgroup: cgroup}) do
    port = Port.open({:spawn_executable, System.find_executable(cmd)}, [:exit_status, args: args])

    # ponytail: the child runs unconfined for the few ms before this write lands
    if cgroup do
      {:os_pid, pid} = Port.info(port, :os_pid)
      File.write!(Path.join(cgroup, "cgroup.procs"), Integer.to_string(pid))
    end

    port
  end
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
