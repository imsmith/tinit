defmodule Sysbeam.Tier do
  @moduledoc """
  Runs the next tier through /sbin/sbexec as a port and respawns it when it
  exits. sbexec sets PR_SET_PDEATHSIG, so if this BEAM dies the child gets
  SIGTERM and takes its own subtree with it.

  Options: `role`, `index`; `args` replaces the default `[role, index]` with
  the full sbexec argument list (easysec passes policy flags this way).
  """
  use GenServer

  @sbexec "/sbin/sbexec"
  @backoff_ms 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    role = Keyword.fetch!(opts, :role)
    args = Keyword.get(opts, :args, [role | List.wrap(opts[:index])])
    {:ok, %{role: role, args: args, port: open(args)}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port, role: role, args: args} = state) do
    Sysbeam.log(role, "#{Enum.join(args, " ")} exited #{status}, respawning in #{@backoff_ms}ms")
    Process.send_after(self(), :respawn, @backoff_ms)
    {:noreply, %{state | port: nil}}
  end

  def handle_info(:respawn, %{args: args} = state), do: {:noreply, %{state | port: open(args)}}
  def handle_info(_, state), do: {:noreply, state}

  # ponytail: fixed backoff, no crash-loop detection
  defp open(args), do: Port.open({:spawn_executable, @sbexec}, [:exit_status, args: args])
end
