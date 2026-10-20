# ltd system config. ltd rewrites this file when the running system drifts.
hostname sysbeam-demo
sysctl kernel.panic 10
sysctl net.ipv4.ip_forward 1
boot cmdline {console=ttyS0 panic=1 quiet}
