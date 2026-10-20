# easysec worker policy. The policy in memory is the authority: easysec enforces it on the cgroups.
# worker INDEX -caps {allow-list} -pids_max N [-console TTY]
# Worker 0 owns the console: IEx on ttyS0. It may power the VM off and touch the network, nothing else.
worker 0 -caps {net_admin sys_boot} -pids_max 128 -context admin_t -console /dev/ttyS0
worker 1 -caps {} -pids_max 64 -context worker_t
