defmodule Sysbeam.Worker.Tree do
  @moduledoc """
  One of the worker's four supervision trees: devices, people, programs,
  networks. Placeholder: a named process that holds. Worker 0's programs tree
  runs the demo shell; when the shell exits this BEAM halts and easysec
  respawns the worker.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: :"tree_#{opts[:name]}")

  @impl true
  def init(opts) do
    Sysbeam.log("worker", "  supervisor:#{opts[:name]} running (pid #{inspect(self())})")
    if opts[:shell?], do: send(self(), :shell)
    {:ok, opts}
  end

  @impl true
  def handle_info(:shell, state) do
    Sysbeam.log("worker", "  programs tree: interactive shell on ttyS0 (exit -> easysec respawns worker)")
    # The port child is already a session leader, so busybox setsid would fork and
    # return at once. The trailing ":" stops ash exec'ing setsid in place, so it
    # runs as a non-leader child, keeps the session in-process, and sh waits on it.
    {out, status} = System.cmd("sh", ["-c", "setsid -c sh </dev/ttyS0 >/dev/ttyS0 2>&1; :"])
    Sysbeam.log("worker", "  shell exited #{status} #{String.trim(out)}")
    System.halt(0)
    {:noreply, state}
  end
end
