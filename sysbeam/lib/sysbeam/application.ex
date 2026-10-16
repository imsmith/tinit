defmodule Sysbeam.Application do
  @moduledoc """
  One application, three roles. The role comes from SYSBEAM_ROLE, set by
  /sbin/sbexec from its ROLE argument.

      tinit -> sysbeam(ltd) -> sysbeam(easysec) -> sysbeam(worker 0..n)

  Each tier's supervisor owns the ports for the next tier (Sysbeam.Tier), so
  a tier's subtree is a child of its supervisor like everything else.
  """
  use Application
  alias Sysbeam.Easysec.{Cgroup, Policy}

  @workers 2

  @impl true
  def start(_type, _args) do
    role = System.get_env("SYSBEAM_ROLE", "ltd")
    index = System.get_env("SYSBEAM_INDEX", "0")
    Sysbeam.log(role, "BEAM VM started (pid #{System.pid()})")

    children = children(role, index)
    Supervisor.start_link(children, strategy: :one_for_one, name: Sysbeam.Supervisor)
  end

  defp children("ltd", _) do
    [
      Sysbeam.Ltd.Mounts,
      Sysbeam.ConfigStore,
      {Sysbeam.Tier, role: "easysec"}
    ]
  end

  defp children("easysec", _) do
    for i <- 0..(@workers - 1), index = Integer.to_string(i) do
      policy = Policy.for_worker(index)
      cgroup = Cgroup.setup!("worker-#{index}", policy)
      Sysbeam.log("easysec", "worker #{index} policy: caps #{inspect(policy.caps)}, pids.max #{policy.pids_max}")

      Supervisor.child_spec(
        {Sysbeam.Tier, role: "worker", index: index, args: Policy.exec(policy, cgroup, ["worker", index])},
        id: {:worker, i}
      )
    end
  end

  defp children("worker", _index) do
    for tree <- ~w(devices people programs networks) do
      Supervisor.child_spec({Sysbeam.Worker.Tree, name: tree}, id: {:tree, tree})
    end
  end

  defp children(other, _) do
    Sysbeam.log(other, "unknown role")
    System.halt(1)
  end
end

defmodule Sysbeam do
  def log(role, msg), do: IO.puts("[sysbeam:#{role}] #{msg}")
end
