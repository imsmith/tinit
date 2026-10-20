defmodule Sysbeam.Application do
  @moduledoc """
  One application, three roles. The role comes from SYSBEAM_ROLE, set by
  /sbin/sbexec from its ROLE argument.

      tinit -> sysbeam(ltd) -> sysbeam(easysec) -> sysbeam(worker 0..n)

  Each tier's supervisor owns the ports for the next tier (Sysbeam.Tier), so
  a tier's subtree is a child of its supervisor like everything else.
  """
  use Application
  alias Sysbeam.Easysec.{Enforcer, Policy, Selinux}

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
      Sysbeam.Ltd.Loopback,
      Sysbeam.ConfigStore,
      {Sysbeam.Tier, role: "easysec"}
    ]
  end

  # A refused policy starts no workers: a security policy with no valid declaration must not guess.
  # The enforcer keeps watching the file, so a fixed file brings the workers up.
  defp children("easysec", _) do
    Selinux.load()

    policy =
      case Policy.load() do
        {:ok, policy} -> policy
        {:error, reason} -> Sysbeam.log("easysec", "policy refused (#{reason}); no workers"); %{}
      end

    workers = for {index, worker} <- Enum.sort(policy), do: Enforcer.worker_spec(index, worker)
    workers ++ [{Enforcer, policy}]
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
