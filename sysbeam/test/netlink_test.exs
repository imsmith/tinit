defmodule Sysbeam.NetlinkTest do
  use ExUnit.Case
  alias Sysbeam.Netlink, as: NL

  test "attributes are 4-byte aligned and parse back" do
    assert NL.attr(3, "br0" <> <<0>>) == <<8::16-native, 3::16-native, "br0", 0>>
    assert NL.attr(10, <<7::32-native>>) == <<8::16-native, 10::16-native, 7::32-native>>
    a = NL.attr(3, NL.string("eth0")) <> NL.attr(10, <<5::32-native>>)
    assert NL.attrs(a) == %{3 => "eth0" <> <<0>>, 10 => <<5::32-native>>}
    assert NL.cstring("eth0" <> <<0>>) == "eth0"
  end

  test "a message is a 16-byte header plus payload; parse walks concatenated messages" do
    msg = NL.message(18, 0x301, NL.ifinfomsg(0, 0, 0))
    assert byte_size(msg) == 32
    assert <<32::32-native, 18::16-native, 0x301::16-native, _::binary>> = msg
    done = NL.message(3, 0, <<0::32>>)
    assert [{18, 0x301, p}, {3, 0, <<0, 0, 0, 0>>}] = NL.parse(msg <> done)
    assert byte_size(p) == 16
  end

  test "nested attributes carry the NESTED flag out and lose it on the way in; items are positional" do
    nest = NL.nest(8, [NL.nest(0, [NL.attr(1, "k")]), NL.nest(0, [NL.attr(1, "j")])])
    assert <<_::16, 0x8008::16-native, _::binary>> = nest
    assert NL.items(NL.attrs(nest)[8]) == [%{1 => "k"}, %{1 => "j"}]
  end

  test "addresses and endpoints round-trip through their wire forms" do
    alias Sysbeam.Netlink.Link
    assert Link.parse_cidr("10.0.0.1/24") == {<<10, 0, 0, 1>>, 24}
    assert Link.ip(<<192, 168, 7, 2>>) == "192.168.7.2"
  end

  test "an odd-length payload is padded in the stream, not in the payload" do
    [{1, 0, "abc"}] = NL.parse(NL.message(1, 0, "abc") <> <<0>>)
  end
end
