# make build  -> full Buildroot build (run inside the 'buildroot' distrobox)
# make run    -> boot it in QEMU on the host
BR := buildroot
build: $(BR)/.config
	$(MAKE) -C $(BR)
$(BR)/.config: configs/x86_64_dev_init_defconfig
	$(MAKE) -C $(BR) defconfig BR2_DEFCONFIG=../$<
run:
	./run_qemu.sh
.PHONY: build run
