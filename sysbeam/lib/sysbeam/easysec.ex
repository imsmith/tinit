defmodule Sysbeam.Easysec.Policy do
  @moduledoc """
  What each worker may do. `caps` is an allow-list: sbexec drops every other
  capability from the bounding set before exec, so nothing in the worker can
  get them back. `pids_max` caps the worker's cgroup. Hardcoded until policy
  outgrows two values per worker; then it moves to /etc/easysec/policy.tcl.
  """

  # Worker 0 owns the console: IEx on ttyS0. It may power the VM off and touch the network, nothing else.
  @workers %{
    "0" => %{caps: ~w(net_admin sys_boot), pids_max: 128, console: "/dev/ttyS0"},
    "1" => %{caps: [], pids_max: 64}
  }

  def for_worker(index), do: Map.fetch!(@workers, index)

  @doc "sbexec arguments that apply `policy` inside `cgroup` and then start `args` (role, index)."
  def exec(%{caps: keep} = policy, cgroup, args) do
    ["-c", cgroup, "-d"] ++
      Enum.flat_map(keep, &["-k", &1]) ++
      if(policy[:console], do: ["-t", policy.console], else: []) ++
      args
  end
end

defmodule Sysbeam.Easysec.Cgroup do
  @moduledoc """
  One cgroup v2 leaf per worker under /sys/fs/cgroup/easysec, pids controller
  on. ltd mounted cgroup2; the BEAMs themselves stay in the root cgroup.
  """
  @root "/sys/fs/cgroup"

  def setup!(name, %{pids_max: max}) do
    dir = Path.join([@root, "easysec", name])
    File.mkdir_p!(dir)
    File.write!(Path.join(@root, "cgroup.subtree_control"), "+pids")
    File.write!(Path.join([@root, "easysec", "cgroup.subtree_control"]), "+pids")
    File.write!(Path.join(dir, "pids.max"), Integer.to_string(max))
    dir
  end
end
