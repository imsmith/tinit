defmodule Sysbeam.Bpf do
  @moduledoc """
  eBPF, enough to police a cgroup's network and devices: a program is raw
  instruction bytes, loaded and attached through bpf(2) in Sysbeam.Sys.
  Constants from linux/bpf.h. No compiler on the image: programs are
  assembled by hand here.
  """
  alias Sysbeam.Sys

  @prog_type_cgroup_skb 8
  @prog_type_cgroup_device 15
  @cgroup_inet_egress 1
  @cgroup_device 6

  # r0 = 0 (drop), exit: every packet the cgroup sends is refused with EPERM.
  @drop <<0xB7, 0, 0, 0, 0, 0, 0, 0, 0x95, 0, 0, 0, 0, 0, 0, 0>>

  def egress, do: @cgroup_inet_egress
  def device, do: @cgroup_device
  def cgroup_skb, do: @prog_type_cgroup_skb
  def cgroup_device, do: @prog_type_cgroup_device
  def drop, do: @drop

  @doc """
  A device program allowing only the `{major, minor}` pairs listed (any
  access, char or block). r1 is the bpf_cgroup_dev_ctx: access_type, major,
  minor as u32 at 0, 4, 8.
  """
  def device_allow(pairs) do
    n = length(pairs)
    # r2 = major, r3 = minor
    head = <<0x61, 0x12, 4::16-little, 0::32, 0x61, 0x13, 8::16-little, 0::32>>
    # per pair: jne r2, major, +1 ; jeq r3, minor, +(2n - 2i) -> allow
    checks =
      for {{major, minor}, i} <- Enum.with_index(pairs), into: "" do
        <<0x55, 0x02, 1::16-little, major::32-little, 0x15, 0x03, 2 * n - 2 * i::16-little, minor::32-little>>
      end

    # deny: r0 = 0, exit ; allow: r0 = 1, exit
    head <> checks <> <<0xB7, 0, 0::16, 0::32, 0x95, 0, 0::16, 0::32, 0xB7, 0, 0::16, 1::32-little, 0x95, 0, 0::16, 0::32>>
  end

  @doc "Load `insns` as `prog_type` and attach to the cgroup directory at `attach_type`; replaces what was there."
  def attach(cgroup, attach_type, prog_type, insns) do
    with {:ok, fd} <- Sys.bpf_prog_load(prog_type, insns, attach_type) do
      try do
        Sys.bpf_prog_attach(fd, cgroup, attach_type)
      after
        Sys.close(fd)
      end
    end
  end

  def detach(cgroup, attach_type), do: Sys.bpf_prog_detach(cgroup, attach_type)

  @doc "How many programs are attached at `attach_type`."
  def attached(cgroup, attach_type), do: Sys.bpf_prog_query(cgroup, attach_type)
end
