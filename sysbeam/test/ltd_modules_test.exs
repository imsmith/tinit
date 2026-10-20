defmodule Sysbeam.Ltd.ModulesTest do
  use ExUnit.Case
  alias Sysbeam.Ltd.Modules

  @dep """
  kernel/net/bridge/bridge.ko: kernel/net/802/stp.ko kernel/net/llc/llc.ko
  kernel/drivers/net/wireguard/wireguard.ko: kernel/net/ipv4/udp_tunnel.ko kernel/lib/crypto/libchacha20poly1305.ko
  kernel/lib/crypto/libchacha20poly1305.ko:
  kernel/drivers/net/my-dashed.ko:
  """

  test "dependencies load first, in modprobe's reverse order, then the module" do
    assert Modules.load_order(@dep, "bridge") == ["kernel/net/llc/llc.ko", "kernel/net/802/stp.ko", "kernel/net/bridge/bridge.ko"]
    assert Modules.load_order(@dep, "libchacha20poly1305") == ["kernel/lib/crypto/libchacha20poly1305.ko"]
  end

  test "a module's name is its file name with underscores; unknown is nil" do
    assert Modules.load_order(@dep, "my_dashed") == ["kernel/drivers/net/my-dashed.ko"]
    assert Modules.load_order(@dep, "nope") == nil
  end
end
