defmodule Sysbeam.Ltd.Mounts do
  @moduledoc "ltd's first job: the virtual filesystems. One-shot, runs before the rest of the tier."
  use Task, restart: :temporary

  @mounts [
    {"proc", "proc", "/proc"},
    {"sysfs", "sys", "/sys"},
    {"devtmpfs", "dev", "/dev"},
    {"tmpfs", "tmp", "/tmp"},
    {"tmpfs", "run", "/run"}
  ]

  def start_link(_), do: Task.start_link(__MODULE__, :run, [])

  def run do
    for {type, name, target} <- @mounts do
      case System.cmd("mount", ["-t", type, name, target], stderr_to_stdout: true) do
        {_, 0} -> Sysbeam.log("ltd", "mounted #{target}")
        {err, _} -> Sysbeam.log("ltd", "mount #{target} skipped: #{String.trim(err)}")
      end
    end
  end
end

defmodule Sysbeam.ConfigStore do
  @moduledoc "ltd's system config as a materialized view. Placeholder: a map, seeded with test data."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def get(key), do: GenServer.call(__MODULE__, {:get, key})
  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})
  def dump, do: GenServer.call(__MODULE__, :dump)

  @impl true
  def init(_) do
    state = %{
      hostname: "sysbeam-test",
      wireguard: %{interface: "wg0", listen_port: 51820, peers: []},
      sysctl: %{"net.ipv4.ip_forward" => 1}
    }

    Sysbeam.log("ltd", "config materialized: #{inspect(state)}")
    Sysbeam.log("ltd", "running -- config reconciliation loop active")
    {:ok, state}
  end

  @impl true
  def handle_call({:get, key}, _from, state), do: {:reply, Map.get(state, key), state}
  def handle_call({:put, key, value}, _from, state), do: {:reply, :ok, Map.put(state, key, value)}
  def handle_call(:dump, _from, state), do: {:reply, state, state}
end
