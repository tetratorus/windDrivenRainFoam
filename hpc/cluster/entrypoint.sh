#!/bin/bash
set -e
cp /etc/munge-shared/munge.key /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key && chmod 400 /etc/munge/munge.key
mkdir -p /run/munge && chown munge:munge /run/munge
su -s /bin/sh munge -c "/usr/sbin/munged --force"
if [ "$1" = compute ]; then
  # cgroup v2 "no internal processes": park existing procs in a leaf so slurmd can delegate controllers
  mkdir -p /sys/fs/cgroup/init
  for p in $(cat /sys/fs/cgroup/cgroup.procs); do echo "$p" > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true; done
  echo "+cpu +cpuset +memory +pids" > /sys/fs/cgroup/cgroup.subtree_control
  mkdir -p /sys/fs/cgroup/system.slice
  echo "+cpu +cpuset +memory +pids" > /sys/fs/cgroup/system.slice/cgroup.subtree_control
fi
case "$1" in
  head)
    # operator web console (wdr-web), runs as the operator account on the login node
    su operator1 -c "WDR_REFERENCE=${WDR_REFERENCE:-/shared/reference/cubicBuilding} /opt/wdr-operator/wdr-web --port 8080 >> /tmp/wdr-web.log 2>&1" &
    exec /usr/sbin/slurmctld -D -i ;;
  compute) exec /usr/sbin/slurmd -D -N "$(hostname)" ;;
  *) exec "$@" ;;
esac
