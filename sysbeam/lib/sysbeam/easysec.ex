defmodule Sysbeam.Easysec.Policy do
  @moduledoc """
  What each worker may do. `caps` is an allow-list: every other capability
  leaves the bounding set before /sbin/sysbeam is exec'd, so nothing in the
  worker, including the demo shell, can get them back. `pids_max` caps the
  worker's cgroup. Hardcoded until policy outgrows two values per worker;
  then it moves to /etc/easysec/policy.tcl like ltd's config.
  """

  # Linux 6.18: capabilities 0..40, in kernel order.
  @caps ~w(chown dac_override dac_read_search fowner fsetid kill setgid setuid setpcap
           linux_immutable net_bind_service net_broadcast net_admin net_raw ipc_lock ipc_owner
           sys_module sys_rawio sys_chroot sys_ptrace sys_pacct sys_admin sys_boot sys_nice
           sys_resource sys_time sys_tty_config mknod lease audit_write audit_control setfcap
           mac_override mac_admin syslog wake_alarm block_suspend audit_read perfmon bpf
           checkpoint_restore)

  # Worker 0 runs the demo shell: it may power the VM off and touch the network, nothing else.
  @workers %{
    "0" => %{caps: ~w(net_admin sys_boot), pids_max: 128},
    "1" => %{caps: [], pids_max: 64}
  }

  def for_worker(index), do: Map.fetch!(@workers, index)

  @doc "argv that applies the policy and execs /sbin/sysbeam with `args`, via libcap's capsh."
  def exec(%{caps: keep}, args) do
    drop = Enum.map_join(@caps -- keep, ",", &("cap_" <> &1))
    ["capsh", "--drop=#{drop}", "--no-new-privs", "--shell=/sbin/sysbeam", "--" | args]
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
