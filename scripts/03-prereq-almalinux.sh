#!/usr/bin/env bash
#
# 03-prereq-almalinux.sh — Prerequisite installation for an AlmaLinux container
# host that runs containers on caller-specified static IPs.
#
# Prepares an AlmaLinux 9 EC2 instance to host containers whose addresses are
# dictated by a plan file (see the usage note below). This script is deliberately
# generic: it declares no addresses, hostnames or workloads of its own —
# everything comes from the plan.
#
# Installs:
#     docker-ce + compose plugin + buildx
#     git, jq, unzip, tar, bind-utils, iproute
#     AWS CLI v2
#     OpenJDK 17 (Jenkins agent)
#     msodbcsql18 + mssql-tools18 (sqlcmd) for DB restore/probe
#     ipvlan kernel module, sysctl tuning for multi-NIC asymmetric routing
#     firewalld trusted zone for eth1/eth2
#     ipvlan L2 Docker networks bound to eth1 / eth2
#     mssql/server:2022-latest image
#
# IP-exactness note: ipvlan in L2 mode is used rather than macvlan because
# ipvlan children share the parent NIC's MAC address. EC2 filters foreign MACs,
# so macvlan fails there while ipvlan works.
#
# Usage:
#   03-prereq-almalinux.sh [/path/to/flow-plan-linux.json]
#
# Nothing about the flow is hardcoded here — networks, container addresses and
# peers all come from the plan file produced by generator/generate_cfn.py.
# Instance UserData passes it in automatically; supply it by hand only when
# re-running manually. Without a plan, tooling is installed but no Docker
# networks are created.
#
# Run as root. CloudFormation now creates the ENIs, assigns the exact production
# addresses as secondary private IPs, and disables source/dest check — so no
# AWS-side preparation is needed here.
#
# Idempotent: safe to re-run.
#
set -euo pipefail

# ─────────────────────────── configuration ───────────────────────────
# Host-level constants only. Flow specifics come from the plan file.

PLAN_FILE="${1:-/opt/flowtest/bootstrap/flow-plan-linux.json}"

MSSQL_IMAGE="mcr.microsoft.com/mssql/server:2022-latest"
ALMALINUX_BASE_IMAGE="almalinux:9"
WORK_ROOT="/opt/flowtest"

SKIP_NETWORKS="${SKIP_NETWORKS:-0}"
SKIP_IMAGES="${SKIP_IMAGES:-0}"

# Populated by load_flow_plan(): parallel arrays, one entry per NIC.
PLAN_LOADED=0
PLAN_FLOW=""
declare -a NET_NAMES=() NET_SUBNETS=() NET_GATEWAYS=() NET_HOST_IPS=() NET_CONTAINER_IPS=()
declare -a PLAN_PEERS=()

# ─────────────────────────── helpers ───────────────────────────
C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
C_RED='\033[0;31m';  C_GREY='\033[0;90m';  C_OFF='\033[0m'

step() { printf '\n%b=== %s ===%b\n' "$C_CYAN"  "$*" "$C_OFF"; }
ok()   { printf '%b  [ok]  %b%s\n'   "$C_GREEN" "$C_OFF" "$*"; }
skip() { printf '%b  [skip] %s%b\n'  "$C_GREY"  "$*" "$C_OFF"; }
warn() { printf '%b  [warn] %b%s\n'  "$C_YELLOW" "$C_OFF" "$*"; }
fail() { printf '%b  [FAIL] %b%s\n'  "$C_RED"   "$C_OFF" "$*"; }
die()  { fail "$*"; exit 1; }

VERIFY_FAILURES=()

assert_root() {
  [[ ${EUID} -eq 0 ]] || die "must run as root (try: sudo $0)"
}

assert_supported_os() {
  step "Operating system"
  [[ -r /etc/os-release ]] || die "/etc/os-release not readable"
  # shellcheck disable=SC1091
  . /etc/os-release
  ok "${PRETTY_NAME:-unknown}"

  case "${ID:-}" in
    almalinux|rocky|rhel|centos) : ;;
    *) warn "expected an EL9 distribution; got '${ID:-?}'. Continuing, but package names may differ." ;;
  esac

  local major="${VERSION_ID%%.*}"
  if [[ "${major}" != "9" ]]; then
    warn "expected EL9; got ${VERSION_ID:-?}. The Microsoft repo URL below is EL9-specific."
  fi
  ok "kernel $(uname -r)"
}

load_flow_plan() {
  step "Flow plan"

  if [[ ! -f "$PLAN_FILE" ]]; then
    warn "no plan file at $PLAN_FILE — installing tooling only, skipping Docker networks"
    warn "generate one with: python3 generator/generate_cfn.py --flow <FLOW> ..."
    return 0
  fi

  # jq is installed by install_base_packages, which runs before this.
  command -v jq >/dev/null || die "jq is required to read the plan file"

  local role
  role="$(jq -r '.hostRole' "$PLAN_FILE")"
  [[ "$role" == "linux" ]] || die "plan file is for hostRole '$role', not 'linux'. Wrong plan file?"

  PLAN_FLOW="$(jq -r '.flow' "$PLAN_FILE")"
  local plan_root
  plan_root="$(jq -r '.workRoot // empty' "$PLAN_FILE")"
  [[ -n "$plan_root" ]] && WORK_ROOT="$plan_root"

  local line
  while IFS=$'\t' read -r name subnet gateway host_ip container_ips; do
    [[ -n "$name" ]] || continue
    NET_NAMES+=("$name")
    NET_SUBNETS+=("$subnet")
    NET_GATEWAYS+=("$gateway")
    NET_HOST_IPS+=("$host_ip")
    NET_CONTAINER_IPS+=("$container_ips")
  done < <(jq -r '.networks[] | [.dockerNetwork, .subnetCidr, .gateway, .hostPrimaryIp, (.containerIps | join(","))] | @tsv' "$PLAN_FILE")

  while read -r line; do
    [[ -n "$line" ]] && PLAN_PEERS+=("$line")
  done < <(jq -r '.peers[]? ' "$PLAN_FILE")

  PLAN_LOADED=1
  ok "flow: $PLAN_FLOW"

  local i
  for i in "${!NET_NAMES[@]}"; do
    ok "$(printf '%s  %s  host=%s  containers=%s' \
      "${NET_NAMES[$i]}" "${NET_SUBNETS[$i]}" "${NET_HOST_IPS[$i]}" "${NET_CONTAINER_IPS[$i]}")"
  done

  while IFS=$'\t' read -r prod_host ip shared services; do
    [[ -n "$prod_host" ]] || continue
    if [[ "$shared" == "true" ]]; then
      ok "group $prod_host @ $ip: $services [shared namespace]"
    else
      ok "group $prod_host @ $ip: $services"
    fi
  done < <(jq -r '.groups[] | [.prodHost, .ip, (.sharedNamespace|tostring), ([.services[].serviceName] | join(", "))] | @tsv' "$PLAN_FILE")

  if jq -e '.database' "$PLAN_FILE" >/dev/null 2>&1; then
    ok "database: $(jq -r '.database.containerName' "$PLAN_FILE") @ $(jq -r '.database.ip' "$PLAN_FILE") ($(jq -r '.database.databases | length' "$PLAN_FILE") db(s) to restore)"
  fi
}

# ─────────────────────────── steps ───────────────────────────

install_base_packages() {
  step "Base packages"
  # nmap-ncat provides nc on EL9 (there is no bare 'nc' package).
  local packages=(dnf-plugins-core git jq unzip tar bind-utils iproute
                  policycoreutils-python-utils nmap-ncat ca-certificates curl)
  local to_install=() pkg
  for pkg in "${packages[@]}"; do
    if rpm -q "$pkg" &>/dev/null; then
      skip "$pkg"
    else
      to_install+=("$pkg")
    fi
  done
  if [[ ${#to_install[@]} -gt 0 ]]; then
    printf '  installing: %s\n' "${to_install[*]}"
    dnf install -y "${to_install[@]}" >/dev/null
    ok "installed ${to_install[*]}"
  fi
}

install_ssm_agent() {
  step "AWS SSM Agent"
  # AlmaLinux AMIs do NOT ship the SSM Agent — unlike Amazon Linux and the AWS
  # Windows AMIs. Without it, `aws ssm start-session` fails with
  # "TargetNotConnected" no matter how correct the instance profile is, and the
  # host is unreachable if no key pair was set. Install it early, before the long
  # docker install, so access is available as soon as possible.
  if systemctl is-active --quiet amazon-ssm-agent 2>/dev/null; then
    skip "amazon-ssm-agent already running"
    return
  fi

  # Region from IMDSv2, falling back to us-east-1.
  local token region url
  token="$(curl -sS -X PUT 'http://169.254.169.254/latest/api/token' \
            -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' --max-time 5 2>/dev/null || true)"
  if [[ -n "$token" ]]; then
    region="$(curl -sS -H "X-aws-ec2-metadata-token: $token" --max-time 5 \
              'http://169.254.169.254/latest/meta-data/placement/region' 2>/dev/null || true)"
  fi
  region="${region:-us-east-1}"
  ok "region $region"

  url="https://s3.${region}.amazonaws.com/amazon-ssm-${region}/latest/linux_amd64/amazon-ssm-agent.rpm"
  printf '  installing from %s\n' "$url"
  if dnf install -y "$url" >/dev/null 2>&1; then
    ok "amazon-ssm-agent installed"
  else
    warn "install from the regional bucket failed; trying the global bucket"
    if dnf install -y \
        "https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm" \
        >/dev/null 2>&1; then
      ok "amazon-ssm-agent installed (global bucket)"
    else
      warn "could not install the SSM Agent - Session Manager will not work on this host"
      warn "you will need a key pair for SSH access instead"
      return
    fi
  fi

  systemctl enable --now amazon-ssm-agent >/dev/null 2>&1 || true
  sleep 3
  if systemctl is-active --quiet amazon-ssm-agent; then
    ok "amazon-ssm-agent running"
    printf '%b    Registration also needs an instance profile with AmazonSSMManagedInstanceCore\n' "$C_GREY"
    printf '    and outbound 443. Confirm from your workstation with:\n'
    printf '      aws ssm describe-instance-information --query "InstanceInformationList[].InstanceId"%b\n' "$C_OFF"
  else
    warn "amazon-ssm-agent installed but not active: journalctl -u amazon-ssm-agent -n 50"
  fi
}

install_docker() {
  step "Docker CE"
  if command -v docker &>/dev/null; then
    skip "already installed ($(docker --version))"
  else
    # AlmaLinux 9 uses Docker's CentOS 9 repository.
    if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
      dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >/dev/null
      ok "docker-ce repo added"
    fi
    printf '  installing docker-ce ...\n'
    dnf install -y docker-ce docker-ce-cli containerd.io \
                   docker-buildx-plugin docker-compose-plugin >/dev/null
    ok "docker-ce installed"
  fi

  systemctl enable --now docker >/dev/null 2>&1 || true
  if systemctl is-active --quiet docker; then
    ok "docker service active"
  else
    die "docker service failed to start — check: journalctl -u docker -n 50"
  fi
}

install_awscli() {
  step "AWS CLI v2"
  if command -v aws &>/dev/null && aws --version 2>&1 | grep -q 'aws-cli/2'; then
    skip "already installed ($(aws --version 2>&1))"
    return
  fi
  local tmp
  tmp="$(mktemp -d)"
  printf '  downloading awscli-exe-linux-x86_64.zip ...\n'
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$tmp/awscliv2.zip"
  unzip -q "$tmp/awscliv2.zip" -d "$tmp"
  "$tmp/aws/install" --update >/dev/null
  rm -rf "$tmp"
  ok "installed ($(aws --version 2>&1))"
}

install_java() {
  step "OpenJDK 17 (Jenkins agent)"
  if rpm -q java-17-openjdk-headless &>/dev/null; then
    skip "already installed"
  else
    dnf install -y java-17-openjdk-headless >/dev/null
    ok "installed"
  fi
  ok "$(java -version 2>&1 | head -n1)"
}

install_mssql_tools() {
  step "SQL Server client tools (msodbcsql18 + sqlcmd)"
  # Needed to restore the .bak files into the SQL Server container and to probe
  # DB reachability from the pipeline.
  if [[ ! -f /etc/yum.repos.d/mssql-release.repo ]]; then
    curl -fsSL https://packages.microsoft.com/config/rhel/9/prod.repo \
      -o /etc/yum.repos.d/mssql-release.repo
    ok "Microsoft EL9 repo added"
  else
    skip "Microsoft repo already present"
  fi

  if rpm -q msodbcsql18 &>/dev/null && rpm -q mssql-tools18 &>/dev/null; then
    skip "msodbcsql18 + mssql-tools18 already installed"
  else
    printf '  installing (accepting EULAs) ...\n'
    ACCEPT_EULA=Y dnf install -y msodbcsql18 mssql-tools18 unixODBC-devel >/dev/null
    ok "installed"
  fi

  local profile='/etc/profile.d/mssql-tools.sh'
  if [[ ! -f "$profile" ]]; then
    echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' > "$profile"
    chmod 0644 "$profile"
    ok "sqlcmd added to PATH via $profile"
  else
    skip "$profile already present"
  fi
  export PATH="$PATH:/opt/mssql-tools18/bin"
}

configure_kernel_networking() {
  step "Kernel networking (ipvlan + multi-NIC routing)"

  if modprobe ipvlan 2>/dev/null; then
    ok "ipvlan module loaded"
  else
    warn "could not modprobe ipvlan — it may be built into the kernel"
  fi
  echo 'ipvlan' > /etc/modules-load.d/ipvlan.conf
  ok "ipvlan set to load at boot"

  # rp_filter must be relaxed: with two NICs in different subnets, replies can
  # arrive on an interface other than the one strict reverse-path filtering
  # expects, and packets get silently dropped.
  local sysctl_file='/etc/sysctl.d/99-flowtest.conf'
  cat > "$sysctl_file" <<'SYSCTL'
# VCVW flow-testing container host
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv6.conf.all.disable_ipv6 = 1
SYSCTL
  sysctl -p "$sysctl_file" >/dev/null
  ok "sysctl applied ($sysctl_file)"
  printf '%b    ip_forward=1, rp_filter=2 (loose) — required for asymmetric multi-NIC paths%b\n' "$C_GREY" "$C_OFF"
}

# Echo the interface name carrying an address inside the given /24, or empty.
find_interface_for_subnet() {
  local cidr="$1"
  local prefix24="${cidr%.*}"          # a.b.c.0/24 -> a.b.c
  ip -o -4 addr show scope global 2>/dev/null \
    | awk -v pfx="$prefix24." '$4 ~ "^"pfx {print $2; exit}'
}

configure_firewalld() {
  step "firewalld"
  if ! systemctl is-active --quiet firewalld; then
    skip "firewalld not active — nothing to do"
    return
  fi

  # firewalld's default filtering interferes with ipvlan traffic. Put the two
  # prod-mirroring NICs in the trusted zone; the intra-VPC-only security group
  # remains the real containment boundary.
  if [[ "$PLAN_LOADED" -ne 1 ]]; then
    skip "no flow plan — no prod-mirroring NICs to place in the trusted zone"
    return
  fi

  local subnet iface
  for subnet in "${NET_SUBNETS[@]}"; do
    iface="$(find_interface_for_subnet "$subnet")"
    if [[ -z "$iface" ]]; then
      warn "no interface found for $subnet — skipping firewalld zone assignment"
      continue
    fi
    if firewall-cmd --zone=trusted --query-interface="$iface" &>/dev/null; then
      skip "$iface already in trusted zone"
    else
      firewall-cmd --permanent --zone=trusted --add-interface="$iface" >/dev/null
      ok "$iface added to trusted zone ($subnet)"
    fi
  done
  firewall-cmd --reload >/dev/null
  ok "firewalld reloaded"
}

report_selinux() {
  step "SELinux"
  local mode
  mode="$(getenforce 2>/dev/null || echo 'unknown')"
  ok "current mode: $mode"
  if [[ "$mode" == "Enforcing" ]]; then
    printf '%b    Keep it enforcing. Mount config volumes with the :Z flag, e.g.\n' "$C_GREY"
    printf '      docker run -v %s/configs/<service>:<container-config-dir>:ro,Z ...%b\n' "$WORK_ROOT" "$C_OFF"
  fi
}

create_ipvlan_network() {
  local name="$1" subnet="$2" gateway="$3" planned_ips="$4"

  if docker network inspect "$name" &>/dev/null; then
    skip "network '$name' already exists"
    return
  fi

  local iface
  iface="$(find_interface_for_subnet "$subnet")"
  if [[ -z "$iface" ]]; then
    warn "no interface carrying an address in $subnet — skipping '$name'"
    warn "check the secondary ENI is attached and has an IP:  ip -br addr"
    VERIFY_FAILURES+=("network:$name")
    return
  fi
  printf '  %s is on interface %s\n' "$subnet" "$iface"

  # ipvlan L2: children share the parent's MAC, so EC2's MAC filtering does not
  # drop the traffic (macvlan would fail here).
  if docker network create \
        --driver ipvlan \
        --subnet "$subnet" \
        --gateway "$gateway" \
        --opt parent="$iface" \
        --opt ipvlan_mode=l2 \
        "$name" >/dev/null; then
    ok "network '$name' created ($subnet via $iface, ipvlan L2)"
    printf '%b         planned container IPs: %s%b\n' "$C_GREY" "$planned_ips" "$C_OFF"
  else
    fail "failed to create network '$name'"
    VERIFY_FAILURES+=("network:$name")
  fi
}

initialize_networks() {
  step "Docker networks (ipvlan L2, prod-exact IPs)"
  if [[ "$SKIP_NETWORKS" == "1" ]]; then
    skip "skipped by SKIP_NETWORKS=1"
    return
  fi
  if [[ "$PLAN_LOADED" -ne 1 ]]; then
    skip "no flow plan — nothing to create"
    return
  fi
  local i
  for i in "${!NET_NAMES[@]}"; do
    create_ipvlan_network "${NET_NAMES[$i]}" "${NET_SUBNETS[$i]}" "${NET_GATEWAYS[$i]}" "${NET_CONTAINER_IPS[$i]}"
  done
  warn "ipvlan containers cannot reach their OWN parent host's IP — by design, do not rely on it"
}

pull_images() {
  step "Container images"
  if [[ "$SKIP_IMAGES" == "1" ]]; then
    skip "skipped by SKIP_IMAGES=1"
    return
  fi
  local image
  for image in "$MSSQL_IMAGE" "$ALMALINUX_BASE_IMAGE"; do
    if docker image inspect "$image" &>/dev/null; then
      skip "$image already present"
    else
      printf '  pulling %s ...\n' "$image"
      if docker pull "$image" >/dev/null; then
        ok "pulled $image"
      else
        fail "could not pull $image"
        VERIFY_FAILURES+=("image:$image")
      fi
    fi
  done
}

initialize_directories() {
  step "Working directories"
  local dirs=(
    "$WORK_ROOT"
    "$WORK_ROOT/configs"
    "$WORK_ROOT/logs"
    "$WORK_ROOT/messages"
    "$WORK_ROOT/artifacts"
    "$WORK_ROOT/mssql/data"
    "$WORK_ROOT/mssql/backup"
  )
  local dir
  for dir in "${dirs[@]}"; do
    if [[ -d "$dir" ]]; then
      skip "$dir"
    else
      mkdir -p "$dir"
      ok "$dir"
    fi
  done
  # The SQL Server container runs as uid 10001 (mssql).
  chown -R 10001:0 "$WORK_ROOT/mssql" 2>/dev/null || warn "could not chown $WORK_ROOT/mssql to 10001:0"
  chmod -R 0770 "$WORK_ROOT/mssql"
  ok "$WORK_ROOT/mssql owned by uid 10001 (mssql container user)"
}

verify() {
  step "Verification"

  local checks=(
    "docker:docker --version"
    "docker compose:docker compose version"
    "git:git --version"
    "aws:aws --version"
    "java:java -version"
    "jq:jq --version"
    "sqlcmd:sqlcmd -?"
  )
  local entry label cmd out
  for entry in "${checks[@]}"; do
    label="${entry%%:*}"; cmd="${entry#*:}"
    if out="$(eval "$cmd" 2>&1 | head -n1)"; then
      ok "$label: $out"
    else
      fail "$label not working"
      VERIFY_FAILURES+=("$label")
    fi
  done

  printf '\n  Docker networks:\n'
  docker network ls | sed 's/^/    /'

  printf '\n  IPv4 addresses on this host:\n'
  ip -br -4 addr show scope global | sed 's/^/    /'

  printf '\n  Remote access:\n'
  if systemctl is-active --quiet amazon-ssm-agent 2>/dev/null; then
    ok "amazon-ssm-agent active (Session Manager should work)"
  else
    warn "amazon-ssm-agent NOT active - Session Manager will report TargetNotConnected"
  fi

  printf '\n  Kernel settings:\n'
  printf '    ip_forward = %s\n' "$(cat /proc/sys/net/ipv4/ip_forward)"
  printf '    rp_filter  = %s (2 = loose, required)\n' "$(cat /proc/sys/net/ipv4/conf/all/rp_filter)"

  if [[ ${#PLAN_PEERS[@]} -gt 0 ]]; then
    printf '\n  Cross-host reachability (peers from the flow plan):\n'
    local target
    for target in "${PLAN_PEERS[@]}"; do
      if ping -c1 -W2 "$target" &>/dev/null; then
        ok "$target reachable"
      else
        warn "$target unreachable (expected until the other host has bootstrapped)"
      fi
    done
  fi

  printf '\n'
  if [[ ${#VERIFY_FAILURES[@]} -gt 0 ]]; then
    fail "incomplete: ${VERIFY_FAILURES[*]}"
    exit 1
  fi
  ok "All AlmaLinux host prerequisites satisfied."
}

print_next_steps() {
  # Rendered from the plan, so this script carries no environment-specific
  # addresses of its own.
  local net="<network>" ip="<ip>"
  if [[ "$PLAN_LOADED" -eq 1 && ${#NET_NAMES[@]} -gt 0 ]]; then
    net="${NET_NAMES[0]}"
    ip="${NET_CONTAINER_IPS[0]%%,*}"
  fi

  printf '\nNext steps\n'
  printf '  1. Smoke-test ipvlan with a static address:\n'
  printf '       docker run --rm --network %s --ip %s %s ip -br addr\n\n' "$net" "$ip" "$ALMALINUX_BASE_IMAGE"

  if [[ "$PLAN_LOADED" -eq 1 ]] && jq -e '.database' "$PLAN_FILE" >/dev/null 2>&1; then
    local db_ip db_net db_name db_count
    db_ip="$(jq -r '.database.ip' "$PLAN_FILE")"
    db_name="$(jq -r '.database.containerName' "$PLAN_FILE")"
    db_count="$(jq -r '.database.databases | length' "$PLAN_FILE")"
    db_net="$(jq -r --arg ip "$db_ip" '.networks[] | select(.containerIps | index($ip)) | .dockerNetwork' "$PLAN_FILE")"
    printf '  2. Start SQL Server and confirm it listens:\n'
    printf '       docker run -d --name %s \\\n' "$db_name"
    printf '         --network %s --ip %s \\\n' "${db_net:-<network>}" "$db_ip"
    printf '         -e ACCEPT_EULA=Y -e MSSQL_PID=Developer \\\n'
    printf '         -e "MSSQL_SA_PASSWORD=<from-your-secret-store>" \\\n'
    printf '         -v %s/mssql/data:/var/opt/mssql/data:Z \\\n' "$WORK_ROOT"
    printf '         -v %s/mssql/backup:/var/opt/mssql/backup:Z \\\n' "$WORK_ROOT"
    printf '         %s\n' "$MSSQL_IMAGE"
    printf '       sqlcmd -S %s -U sa -P "<pwd>" -C -Q "SELECT @@VERSION"\n\n' "$db_ip"

    printf '  3. Validate the backup restore early. Restoring a Windows-authored .bak\n'
    printf '     onto SQL Server on Linux is usually fine at matching major versions,\n'
    printf '     but confirm with the real files (%s to restore). For each:\n' "$db_count"
    printf '       aws s3 cp s3://<archive-bucket>/<database.s3Path>/<backupFile> %s/mssql/backup/\n' "$WORK_ROOT"
    printf '       sqlcmd -S %s -U sa -P "<pwd>" -C -Q \\\n' "$db_ip"
    printf '         "RESTORE FILELISTONLY FROM DISK=%s/var/opt/mssql/backup/<backupFile>%s"\n' "'" "'"
    printf '     Note the MOVE targets become Linux paths under /var/opt/mssql/data/.\n'
    printf '     The exact paths are in the plan file: %s\n\n' "$PLAN_FILE"
  fi

  printf '  4. Build the engine images for the tags named in the plan.\n'
  printf '  5. Register this host as a Jenkins agent (JDK 17 is installed).\n\n'
}

main() {
  printf '\n  VCVW Flow — AlmaLinux container host prerequisites\n'
  printf '%b  -------------------------------------------------%b\n' "$C_GREY" "$C_OFF"

  assert_root
  assert_supported_os

  install_base_packages   # provides jq, needed by load_flow_plan
  load_flow_plan
  install_ssm_agent       # early: restores access if no key pair was set
  install_docker
  install_awscli
  install_java
  install_mssql_tools
  configure_kernel_networking
  configure_firewalld
  report_selinux
  initialize_directories
  pull_images
  initialize_networks
  verify
  print_next_steps
}

main "$@"
