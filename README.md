# flowtest-host-bootstrap

Prerequisite installation scripts for the container hosts of a dockerized
flow-testing environment.

- `scripts/02-prereq-windows.ps1` — Windows Server 2022 host: Containers feature,
  Mirantis Container Runtime, git/AWS CLI/JDK, SQL Server client tools, and
  `l2bridge` Docker networks.
- `scripts/03-prereq-almalinux.sh` — AlmaLinux 9 host: docker-ce, tooling,
  `msodbcsql18`, kernel settings for multi-NIC routing, and `ipvlan` L2 Docker
  networks.

Both are **entirely plan-driven**: every network, address, container group and
peer comes from a `flow-plan-<role>.json` passed in at run time. Neither script
contains any environment-specific value, which is why this repo can be public.

    ./scripts/03-prereq-almalinux.sh /path/to/flow-plan-linux.json
    powershell -File scripts\02-prereq-windows.ps1 -PlanFile flow-plan-windows.json

Both are idempotent and safe to re-run. Published from a private tooling repo;
edit them there, not here.
