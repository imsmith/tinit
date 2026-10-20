defmodule Sysbeam.BpfTest do
  use ExUnit.Case, async: true
  alias Sysbeam.Bpf

  test "the device allow-list program is well-formed: 8-byte insns, jumps land on the allow block" do
    prog = Bpf.device_allow([{1, 3}, {4, 64}])
    insns = for <<i::binary-size(8) <- prog>>, do: i
    assert length(insns) == 2 + 2 * 2 + 4
    # jeq for pair 0 at index 3 jumps 4 to index 8 (r0 = 1); for pair 1 at index 5 jumps 2 to index 8
    assert Enum.at(insns, 3) == <<0x15, 0x03, 4::16-little, 3::32-little>>
    assert Enum.at(insns, 5) == <<0x15, 0x03, 2::16-little, 64::32-little>>
    assert Enum.at(insns, 8) == <<0xB7, 0, 0::16, 1::32-little>>
    assert Enum.at(insns, 6) == <<0xB7, 0, 0::16, 0::32>>
    assert List.last(insns) == <<0x95, 0, 0::16, 0::32>>
  end

  test "an empty allow-list denies everything" do
    assert byte_size(Bpf.device_allow([])) == 6 * 8
  end
end
