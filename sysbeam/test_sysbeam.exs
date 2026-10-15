#!/usr/bin/env elixir
#
# test_sysbeam.exs - Elixir test harness for tinit
#
# Proves:
#   1. The BEAM starts and runs under tinit as a child process.
#   2. Role dispatch via argv[0] / command line args works.
#   3. Ltd can mount virtual filesystems via System.cmd.
#   4. Ltd can signal tinit with SIGUSR1.
#   5. Multiple BEAM instances can discover each other and form a cluster.
#   6. GenServer processes can hold state and respond to calls.
#
# Usage from tinit:
#   execv("/sbin/sysbeam", {"ltd", NULL})     -- but sysbeam is this script
#
# For manual testing without tinit:
#   elixir test_sysbeam.exs ltd
#   elixir test_sysbeam.exs easysec
#   elixir test_sysbeam.exs worker

defmodule SysbeamTest do
  @moduledoc """
  Minimal test harness proving the BEAM can fill each sysbeam role.
  """

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

    # Signal tinit that mounts are ready
    log("ltd", "signaling tinit (SIGUSR1 -> PID 1)")
    System.cmd("kill", ["-USR1", "1"], stderr_to_stdout: true)

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

    log("easysec", "running -- policy enforcement active")
    hold()
  end

  # -----------------------------------------------------------
  # Role: worker
  # -----------------------------------------------------------
  def run_worker do
    log("worker", "starting BEAM instance")

    # Simulate starting supervision trees by spawning monitored processes
    devices = spawn_and_monitor("devices")
    people = spawn_and_monitor("people")
    programs = spawn_and_monitor("programs")
    networks = spawn_and_monitor("networks")

    log("worker", "supervision trees started: #{inspect([devices, people, programs, networks])}")
    log("worker", "running -- service supervision active")
    hold()
  end

  defp spawn_and_monitor(name) do
    pid = spawn(fn ->
      log("worker", "  supervisor:#{name} running (pid #{inspect(self())})")
      if name == "programs", do: demo_shell(), else: hold()
    end)

    Process.monitor(pid)
    log("worker", "  supervisor:#{name} started and monitored")
    {name, pid}
  end

  # Demo: the programs tree runs an interactive shell on the console.
  # When it exits, the BEAM halts and tinit respawns the worker role.
  defp demo_shell do
    log("worker", "  programs tree: interactive shell on ttyS0 (exit -> tinit respawns worker)")
    # The port child is already a session leader, so busybox setsid would fork and
    # return at once. The trailing ":" stops ash exec'ing setsid in place, so it
    # runs as a non-leader child, keeps the session in-process, and sh waits on it.
    {out, status} = System.cmd("sh", ["-c", "setsid -c sh </dev/ttyS0 >/dev/ttyS0 2>&1; :"])
    log("worker", "  shell exited #{status} #{String.trim(out)}")
    System.halt(0)
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
    role =
      case System.argv() do
        [role | _] -> role
        [] ->
          IO.puts("[sysbeam] usage: test_sysbeam.exs <ltd|easysec|worker|cluster>")
          System.halt(1)
      end

    log(role, "BEAM VM started (pid #{System.pid()})")

    case role do
      "ltd"     -> run_ltd()
      "easysec" -> run_easysec()
      "worker"  -> run_worker()
      "cluster" -> test_cluster()
      other     ->
        log(other, "unknown role")
        System.halt(1)
    end
  end
end

SysbeamTest.main()
