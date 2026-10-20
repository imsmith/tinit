defmodule Sysbeam.Tier do
  @moduledoc """
  Runs the next tier through /sbin/sbexec as a port and respawns it when it
  exits. sbexec sets PR_SET_PDEATHSIG, so if this BEAM dies the child gets
  SIGTERM and takes its own subtree with it.

  Options: `role`, `index`; `args` replaces the default `[role, index]` with
  the full sbexec argument list (easysec passes policy flags this way).

  Closing the port does not kill the child, so `terminate/2` sends it SIGTERM:
  a restarted Tier would otherwise spawn a second copy beside the live one.

  A child that dies within `@healthy_ms` of starting is crash-looping: the
  respawn delay doubles each time up to `@max_backoff_ms`. One that lived
  longer resets the delay to `@backoff_ms`.
  """
  use GenServer

  @sbexec "/sbin/sbexec"
  @backoff_ms 1_000
  @max_backoff_ms 60_000
  @healthy_ms 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    role = Keyword.fetch!(opts, :role)
    args = Keyword.get(opts, :args, [role | List.wrap(opts[:index])])
    {:ok, %{role: role, args: args, port: open(args), started: now(), backoff: @backoff_ms}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port, role: role, args: args} = state) do
    backoff = next_backoff(now() - state.started, state.backoff)
    Sysbeam.log(role, "#{Enum.join(args, " ")} exited #{status}, respawning in #{backoff}ms")
    Process.send_after(self(), :respawn, backoff)
    {:noreply, %{state | port: nil, backoff: backoff}}
  end

  def handle_info(:respawn, %{args: args} = state), do: {:noreply, %{state | port: open(args), started: now()}}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    {:os_pid, pid} = Port.info(port, :os_pid)
    Sysbeam.Sys.kill(pid, Sysbeam.Sys.sigterm())
  end

  def terminate(_, _), do: :ok

  # ponytail: terminate/2 does not run when this GenServer itself crashes; the
  # orphan then survives until its own tier goes down. Fine for a 20-line server.
  @doc false
  def next_backoff(uptime_ms, backoff) when uptime_ms < @healthy_ms, do: min(backoff * 2, @max_backoff_ms)
  def next_backoff(_, _), do: @backoff_ms

  defp now, do: System.monotonic_time(:millisecond)
  defp open(args), do: Port.open({:spawn_executable, @sbexec}, [:exit_status, args: args])
end
