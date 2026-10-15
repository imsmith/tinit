#!/usr/bin/env elixir
#
# test_sysbeam.exs - Elixir test harness for tinit
#
# Topology:  tinit -> sysbeam(ltd) -> sysbeam(easysec) -> sysbeam(worker 0..n)
#
# Proves:
#   1. The BEAM starts and runs under tinit as a child process.
#   2. Role dispatch via argv works.
#   3. Ltd can mount virtual filesystems via System.cmd.
#   4. Each tier starts the next as a port, and respawns it when it exits.
#   5. A child tier halts when its parent BEAM dies (stdin EOF on the port pipe).
#   6. GenServer processes can hold state and respond to calls.
#
# Usage from tinit:
#   execv("/sbin/sysbeam", {"ltd", "ltd", NULL})
#
# For manual testing without tinit:
#   elixir test_sysbeam.exs ltd
#   elixir test_sysbeam.exs easysec
#   elixir test_sysbeam.exs worker 0

defmodule SysbeamTest do
  @moduledoc """
  Minimal test harness proving the BEAM can fill each sysbeam role.
  """

  @workers 2
  @sysbeam "/sbin/sysbeam"

  # -----------------------------------------------------------
  # Fake GenServer for ltd: holds system config as a map in ETS
  # -----------------------------------------------------------
  defmodule ConfigStore do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, %{}, Keyword.put(opts, :name, __MODULE__))
    end

    def get(key), do: GenServer.call(__MODULE__, {:get, key})
    def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})
    def dump, do: GenServer.call(__MODULE__, :dump)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:get, key}, _from, state) do
      {:reply, Map.get(state, key), state}
    end

    def handle_call({:put, key, value}, _from, state) do
      {:reply, :ok, Map.put(state, key, value)}
    end

    def handle_call(:dump, _from, state) do
      {:reply, state, state}
    end
  end

  # -----------------------------------------------------------
  # Fake GenServer for easysec: holds security policy
  # -----------------------------------------------------------
  defmodule PolicyStore do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, %{}, Keyword.put(opts, :name, __MODULE__))
    end

    def add_rule(rule), do: GenServer.call(__MODULE__, {:add_rule, rule})
    def policies, do: GenServer.call(__MODULE__, :policies)

    @impl true
    def init(_), do: {:ok, %{rules: []}}

    @impl true
    def handle_call({:add_rule, rule}, _from, %{rules: rules} = state) do
      {:reply, :ok, %{state | rules: [rule | rules]}}
    end

    def handle_call(:policies, _from, state) do
      {:reply, state.rules, state}
    end
  end

  # -----------------------------------------------------------
  # Logging
  # -----------------------------------------------------------
  defp log(role, msg) do
    IO.puts("[sysbeam:#{role}] #{msg}")
  end

  # -----------------------------------------------------------
  # Role: ltd
  # -----------------------------------------------------------
  def run_ltd do
    log("ltd", "starting BEAM instance")

    # Mount virtual filesystems (will fail gracefully if not root or already mounted)
    mounts = [
      {"proc",     "proc",     "/proc"},
      {"sysfs",    "sys",      "/sys"},
      {"devtmpfs", "dev",      "/dev"},
      {"tmpfs",    "tmp",      "/tmp"},
      {"tmpfs",    "run",      "/run"}
    ]

    for {type, name, target} <- mounts do
      case System.cmd("mount", ["-t", type, name, target], stderr_to_stdout: true) do
        {_, 0} -> log("ltd", "mounted #{target}")
        {err, _} -> log("ltd", "mount #{target} skipped: #{String.trim(err)}")
      end
    end

    # Start the config store GenServer
    {:ok, _pid} = ConfigStore.start_link()
    log("ltd", "config store started")

    # Populate some test config (simulating YANG model materialization)
    ConfigStore.put(:hostname, "sysbeam-test")
    ConfigStore.put(:wireguard, %{interface: "wg0", listen_port: 51820, peers: []})
    ConfigStore.put(:sysctl, %{"net.ipv4.ip_forward" => 1})

    config = ConfigStore.dump()
    log("ltd", "config materialized: #{inspect(config)}")

    # Mounts are ready: start the next tier and keep it alive
    supervise("easysec", [])

    log("ltd", "running -- config reconciliation loop active")
    hold()
  end

  # -----------------------------------------------------------
  # Role: easysec
  # -----------------------------------------------------------
  def run_easysec do
    log("easysec", "starting BEAM instance")

    {:ok, _pid} = PolicyStore.start_link()
    log("easysec", "policy store started")

    # Load some test policies
    PolicyStore.add_rule(%{action: :allow, subject: "worker", resource: "network", caps: [:net_admin]})
    PolicyStore.add_rule(%{action: :deny, subject: "worker", resource: "raw_socket", caps: []})

    policies = PolicyStore.policies()
    log("easysec", "policies loaded: #{inspect(policies)}")

    # Start the worker tier under the policy umbrella
    for i <- 0..(@workers - 1), do: supervise("worker", [Integer.to_string(i)])

    log("easysec", "running -- policy enforcement active")
    hold()
  end

  # -----------------------------------------------------------
  # Role: worker
  # -----------------------------------------------------------
  def run_worker(index) do
    log("worker", "starting BEAM instance (worker #{index})")

    # Simulate starting supervision trees by spawning monitored processes
    devices = spawn_and_monitor("devices")
    people = spawn_and_monitor("people")
    programs = spawn_and_monitor("programs", index == "0")
    networks = spawn_and_monitor("networks")

    log("worker", "supervision trees started: #{inspect([devices, people, programs, networks])}")
    log("worker", "running -- service supervision active")
    hold()
  end

  defp spawn_and_monitor(name, shell? \\ false) do
    pid = spawn(fn ->
      log("worker", "  supervisor:#{name} running (pid #{inspect(self())})")
      if shell?, do: demo_shell(), else: hold()
    end)

    Process.monitor(pid)
    log("worker", "  supervisor:#{name} started and monitored")
    {name, pid}
  end

  # Demo: worker 0's programs tree runs an interactive shell on the console.
  # When it exits, this BEAM halts and easysec respawns the worker.
  defp demo_shell do
    log("worker", "  programs tree: interactive shell on ttyS0 (exit -> easysec respawns worker)")
    # The port child is already a session leader, so busybox setsid would fork and
    # return at once. The trailing ":" stops ash exec'ing setsid in place, so it
    # runs as a non-leader child, keeps the session in-process, and sh waits on it.
    {out, status} = System.cmd("sh", ["-c", "setsid -c sh </dev/ttyS0 >/dev/ttyS0 2>&1; :"])
    log("worker", "  shell exited #{status} #{String.trim(out)}")
    System.halt(0)
  end

  # -----------------------------------------------------------
  # Tier supervision: run the next role as a port, respawn on exit
  # -----------------------------------------------------------
  defp supervise(role, args) do
    spawn_link(fn -> supervise_loop(role, args) end)
  end

  defp supervise_loop(role, args) do
    port = Port.open({:spawn_executable, @sysbeam}, [:exit_status, args: [role | args]])
    receive do
      {^port, {:exit_status, status}} ->
        log(role, "#{Enum.join([role | args], " ")} exited #{status}, respawning in 1s")
        Process.sleep(1000)
        supervise_loop(role, args)
    end
  end

  # A child tier's stdin is the pipe from its parent's port. EOF means the
  # parent BEAM is gone, so halt and let the grandparent's respawn rebuild us.
  defp watch_parent do
    spawn(fn ->
      IO.read(:stdio, :eof)
      log("main", "parent gone (stdin EOF), halting")
      System.halt(0)
    end)
  end

  # -----------------------------------------------------------
  # Cluster test (run manually to verify node discovery)
  # -----------------------------------------------------------
  def test_cluster do
    log("cluster", "testing node connectivity")

    nodes = Node.list()
    log("cluster", "connected nodes: #{inspect(nodes)}")

    if nodes == [] do
      log("cluster", "no peers found (expected if running standalone)")
    else
      for node <- nodes do
        log("cluster", "  ping #{node}: #{inspect(Node.ping(node))}")
      end
    end
  end

  # -----------------------------------------------------------
  # Hold the process alive
  # -----------------------------------------------------------
  defp hold do
    receive do
      msg -> log("main", "received: #{inspect(msg)}")
      hold()
    end
  end

  # -----------------------------------------------------------
  # Entry point: dispatch on role
  # -----------------------------------------------------------
  def main do
    # In real sysbeam, the role comes from argv[0] via the execv trick.
    # For testing, we accept it as a command line argument.
    {role, args} =
      case System.argv() do
        [role | args] -> {role, args}
        [] ->
          IO.puts("[sysbeam] usage: test_sysbeam.exs <ltd|easysec|worker N|cluster>")
          System.halt(1)
      end

    log(role, "BEAM VM started (pid #{System.pid()})")
    if role != "ltd", do: watch_parent()

    case {role, args} do
      {"ltd", _}         -> run_ltd()
      {"easysec", _}     -> run_easysec()
      {"worker", [i | _]} -> run_worker(i)
      {"worker", []}     -> run_worker("0")
      {"cluster", _}     -> test_cluster()
      {other, _} ->
        log(other, "unknown role")
        System.halt(1)
    end
  end
end

SysbeamTest.main()
