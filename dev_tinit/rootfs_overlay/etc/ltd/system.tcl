# ltd system config. ltd rewrites this file when the running system drifts.
hostname sysbeam-demo
sysctl kernel.panic 10
sysctl net.ipv4.ip_forward 1
module bridge
module wireguard
bridge br0 eth0
wireguard wg0 -port 51820 -key /etc/ltd/wg0.key
peer wg0 pJc/x1GitwZ0Zy2Ddt5QKe4eGchgREgagV1pZm9TNBk= -allowed {10.0.0.2/32} -endpoint 192.168.7.2:51820
address br0 192.168.7.1/24
address wg0 10.0.0.1/24
boot cmdline {console=ttyS0 panic=1 quiet}
