# Stand-in for the AWS HPC cluster (e.g. AWS ParallelCluster / PCS): Slurm + Apptainer nodes.
# Node OS is intentionally independent of the solver image; nothing is compiled here.
FROM ubuntu@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      slurm-wlm slurm-client munge libpmix2t64 libpmix-dev ca-certificates curl python3 python3-boto3 \
      squashfs-tools fuse2fs fuse-overlayfs iproute2 procps \
    && rm -rf /var/lib/apt/lists/*
ARG APPTAINER_DEB=https://github.com/apptainer/apptainer/releases/download/v1.5.5/apptainer_1.5.5_amd64.deb
ARG APPTAINER_SHA256=25095d3711504b3e8657dbb2e172ef8db9db43c4503d940c9c36b105db8dce77
RUN curl -fsSL -o /tmp/apptainer_1.5.5_amd64.deb "$APPTAINER_DEB" \
    && echo "$APPTAINER_SHA256  /tmp/apptainer_1.5.5_amd64.deb" | sha256sum -c - \
    && apt-get update && apt-get install -y --no-install-recommends /tmp/apptainer_1.5.5_amd64.deb \
    && rm -rf /var/lib/apt/lists/* /tmp/*.deb
RUN usermod -l operator1 -d /home/operator1 -m ubuntu && groupmod -n operator1 ubuntu && \
    mkdir -p /var/spool/slurmctld /var/spool/slurmd /var/log/slurm /run/munge && \
    chown slurm:slurm /var/spool/slurmctld /var/log/slurm
COPY slurm.conf cgroup.conf /etc/slurm/
COPY entrypoint.sh /entrypoint.sh
RUN ln -s /opt/wdr-operator/wdr /usr/local/bin/wdr
ENTRYPOINT ["/entrypoint.sh"]
