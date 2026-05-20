#!/usr/bin/env bash
# =============================================================================
# ChirpStack LoRaWAN Gateway — Universal Setup
# =============================================================================
# Platform  : Armbian Trixie on Rock Pi 4B+ (RK3399)
# HAT       : Nebra Indoor LoRa HAT (SX1302 or SX1301 variant)
# Region    : EU868
# Stack     : ChirpStack v4  (concentratord + mqtt-forwarder + server)
#             with PostgreSQL, Redis, and Mosquitto
#
# Fixes applied
# -------------
# 1. SPI1 DT overlay     — enables /dev/spidev1.0; avoids jedec-nor MTD conflict
# 2. udev rules          — spi/gpio group ownership for the chirpstack process
# 3. ZMQ socket cleanup  — ExecStartPre clears stale /tmp/concentratord_* sockets
# 4. pg_trgm extension   — required by ChirpStack v4 migrations
# 5. Rock Pi 4B+ GPIO    — POWER_EN on gpiochip4:3 (header pin 12) held HIGH
#                          SX130x NRESET on gpiochip4:22 (header pin 11)
#                          POWER_EN held via daemonized gpioset; NRESET owned by concentratord
#
# Usage
# -----
#   sudo bash setup.sh              # auto-detect concentrator type, interactive
#   sudo bash setup.sh --sx1302     # force SX1302 (RAK2287, Nebra HAT rev >= 3)
#   sudo bash setup.sh --sx1301     # force SX1301 (GL5712-UX / RAK2245, older HAT)
#   sudo bash setup.sh --yes        # non-interactive (accepts SX1302 default)
#
# After setup completes a REBOOT is required to activate the SPI1 DT overlay.
# The hardware services (concentratord, mqtt-forwarder) start automatically
# on the next boot once /dev/spidev1.0 is present.
#
# Idempotent: safe to re-run.  Credentials are stored in
#   /etc/chirpstack/.setup-state  (chmod 600) and reused on subsequent runs.
#
# NOTE: chirpstack-concentratord-sx1301 is not in the ChirpStack APT repo.
#       It is downloaded directly from artifacts.chirpstack.io.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Rock Pi 4B+ hardware constants
# -----------------------------------------------------------------------------
readonly SPI_DEV="/dev/spidev1.0"

# NRESET line: header pin 11 = GPIO4_C6 = gpiochip4 line 22 = sysfs GPIO 150
readonly RESET_CHIP="gpiochip4"
readonly RESET_LINE=22
readonly RESET_GPIO_SYSFS=150

# POWER_EN line: header pin 12 = GPIO4_A3 = gpiochip4 line 3 = sysfs GPIO 131
# Required to power the TCXO on the RAK2287/GL5712 module.
# Without this, RF calibration always fails (chip version reads 0x00).
readonly POWER_EN_LINE=3
readonly POWER_EN_GPIO_SYSFS=131

# -----------------------------------------------------------------------------
# LoRaWAN defaults
# -----------------------------------------------------------------------------
readonly REGION="eu868"
readonly NET_ID="000000"

# SX1301 concentratord — not in APT repo, download directly
readonly SX1301_DEB_URL="https://artifacts.chirpstack.io/downloads/chirpstack-concentratord/chirpstack-concentratord-sx1301_4.7.1_linux_arm64.deb"
readonly SX1301_DEB="/tmp/chirpstack-concentratord-sx1301.deb"

# Persistent state file
readonly STATE_FILE="/etc/chirpstack/.setup-state"

# Colours
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
    MAGENTA='\033[0;35m'; ORANGE='\033[0;33m'; WHITE='\033[1;37m'
    BG_RED='\033[41m'; BG_DARK='\033[40m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
    MAGENTA=''; ORANGE=''; WHITE=''; BG_RED=''; BG_DARK=''
fi

# =============================================================================
# Helper functions
# =============================================================================

die()  { echo -e "${RED}ERROR: $*${RESET}" >&2; exit 1; }
log()  { echo -e "\n${CYAN}${BOLD}==> $*${RESET}"; }
info() { echo -e "    ${GREEN}✓${RESET} $*"; }
warn() { echo -e "    ${YELLOW}!${RESET} $*"; }

check_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must be run as root (use sudo)."
}

# Fix clock — fresh Armbian has no RTC battery so the clock is wrong on first
# boot. Repository signature verification fails with "not live until" errors
# if the system time is in the past.
step_fix_clock() {
    log "Fixing system clock (fresh Armbian has no RTC)"

    timedatectl set-ntp true
    systemctl restart systemd-timesyncd 2>/dev/null || true

    # Wait up to 60 seconds for NTP sync - show animated progress bar
    local i=0 total=60 bar_width=40
    while [ $i -lt $total ]; do
        if timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
            printf "\r    ✓ NTP synchronised in %ds%-45s\n" "$i" " "
            info "Clock: $(date)"
            return
        fi
        local filled=$(( i * bar_width / total ))
        local empty=$(( bar_width - filled ))
        local bar="" j=0
        while [ $j -lt $filled ]; do bar="${bar}█"; j=$((j+1)); done
        while [ $j -lt $bar_width ]; do bar="${bar}░"; j=$((j+1)); done
        printf "\r    NTP sync [%s] %2ds remaining  " "$bar" "$(( total - i ))"
        sleep 1
        i=$((i+1))
    done
    printf "\n"

    warn "NTP sync timed out - trying HTTP time fallback"

    # Fallback: get time from HTTP Date header
    local http_date
    http_date=$(curl -sI --max-time 5 http://google.com 2>/dev/null \
        | grep -i "^date:" | cut -d" " -f2- | tr -d "\r" || true)

    if [ -n "$http_date" ]; then
        if date -s "$http_date" >/dev/null 2>&1; then
            info "Clock set from HTTP fallback: $(date)"
            return
        fi
    fi

    warn "Could not sync clock automatically. Current time: $(date)"
    warn "If apt fails with not-live-until errors, run:"
    warn "  date -s \"\$(curl -sI http://google.com | grep -i ^date: | cut -d\' \' -f2-)\""
    warn "Then re-run this script."
}

# Fix Armbian repos — the Armbian beta repo ships broken/404 packages that
# cause apt-get upgrade to fail. We disable ALL Armbian repos since we only
# need the standard Debian repos to install ChirpStack.
# The Armbian kernel and bootloader are already installed and don't need upgrading.
step_fix_armbian_repos() {
    log "Disabling Armbian repos (not needed for ChirpStack)"
    local fixed=0
    for f in /etc/apt/sources.list.d/*.list               /etc/apt/sources.list.d/*.sources; do
        [ -f "$f" ] || continue
        if grep -ql "armbian\|configng\|beta.armbian\|fi.mirror.armbian\|github.armbian" "$f" 2>/dev/null; then
            mv "$f" "${f}.disabled"
            warn "Disabled: $f"
            fixed=1
        fi
    done
    [ $fixed -eq 0 ] && info "No Armbian repos found"
    info "Using Debian stable repos only"
}

derive_gateway_eui() {
    local mac first
    # Try end0 first (Rock Pi wired ethernet), then eth0, then wlan0 as last resort
    for iface in end0 eth0 wlan0; do
        mac=$(cat "/sys/class/net/${iface}/address" 2>/dev/null) || continue
        first=$(printf '%d' "0x${mac%%:*}")
        [ $(( first & 2 )) -eq 0 ] && { echo "${mac}"; return; }
    done
    for iface in end0 eth0 wlan0; do
        cat "/sys/class/net/${iface}/address" 2>/dev/null && return
    done
    echo "00:00:00:00:00:00"
}

detect_concentrator_hw() {
    if [ -f /proc/device-tree/hat/product ]; then
        local product
        product=$(tr -d '\0' < /proc/device-tree/hat/product 2>/dev/null)
        case "${product,,}" in
            *sx1302*|*1302*|*rak2287*|*corecell*) echo "sx1302"; return ;;
            *sx1301*|*1301*|*rak2245*|*rak831*|*gl5712*) echo "sx1301"; return ;;
        esac
    fi

    if command -v i2cdetect >/dev/null 2>&1; then
        local bus product_str
        for bus in 0 1 6 7; do
            [ -e "/dev/i2c-${bus}" ] || continue
            if i2cdetect -y "$bus" 2>/dev/null | grep -q " 50"; then
                product_str=$(i2cdump -y -r 0x14-0x2C "$bus" 0x50 b 2>/dev/null \
                               | awk '{for(i=2;i<=NF;i++) printf $i}' \
                               | xxd -r -p 2>/dev/null | tr -d '\0' || true)
                case "${product_str,,}" in
                    *sx1302*|*1302*|*rak2287*) echo "sx1302"; return ;;
                    *sx1301*|*1301*|*rak2245*|*gl5712*) echo "sx1301"; return ;;
                esac
            fi
        done
    fi

    echo ""
}

# =============================================================================
# Setup steps
# =============================================================================

step_spi_overlay() {
    log "Fix 1 — SPI1 DT overlay (NOR flash conflict prevention)"

    local env=/boot/armbianEnv.txt
    [ -f "$env" ] || die "armbianEnv.txt not found — is this Armbian?"

    sed -i '/^overlays=/d; /^param_spidev/d; /^param_spinor/d' "$env"

    cat >> "$env" <<'EOF'

# -- ChirpStack LoRa HAT (Nebra SX1302/SX1301) --------------------------------
overlays=rk3399-spi-spidev
param_spidev_spi_bus=1
param_spidev_max_freq=2000000
# -----------------------------------------------------------------------------
EOF

    info "armbianEnv.txt updated — /dev/spidev1.0 will appear after reboot"
}

step_install_packages() {
    local chip_type="$1"

    log "Installing system packages"
    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get install -y -qq \
        postgresql postgresql-contrib \
        redis-server \
        mosquitto mosquitto-clients \
        gpiod libgpiod-dev \
        i2c-tools \
        curl gnupg apt-transport-https ca-certificates \
        openssl

    log "Adding ChirpStack APT repository"
    mkdir -p /etc/apt/keyrings/
    wget -q -O - https://artifacts.chirpstack.io/packages/chirpstack.key \
        | gpg --dearmor > /etc/apt/keyrings/chirpstack.gpg
    echo "deb [signed-by=/etc/apt/keyrings/chirpstack.gpg] https://artifacts.chirpstack.io/packages/4.x/deb stable main" \
        > /etc/apt/sources.list.d/chirpstack.list
    apt-get update -qq

    log "Installing ChirpStack v4 packages"
    # chirpstack-mqtt-forwarder replaces gateway-bridge for concentratord backend
    apt-get install -y -qq \
        chirpstack \
        chirpstack-mqtt-forwarder

    # concentratord: sx1302 is in the APT repo; sx1301 requires direct download
    if [ "$chip_type" = "sx1302" ]; then
        apt-get install -y -qq chirpstack-concentratord-sx1302
    else
        log "Downloading chirpstack-concentratord-sx1301 (not in APT repo)"
        curl -fsSL "$SX1301_DEB_URL" -o "$SX1301_DEB"
        dpkg -i "$SX1301_DEB"
        rm -f "$SX1301_DEB"
    fi
}

step_user_groups() {
    log "System user and hardware access groups"

    for grp in spi gpio; do
        getent group "$grp" >/dev/null 2>&1 || groupadd --system "$grp"
    done

    id chirpstack >/dev/null 2>&1 || \
        useradd --system --no-create-home --shell /usr/sbin/nologin chirpstack

    for grp in spi gpio; do
        usermod -aG "$grp" chirpstack
    done

    info "chirpstack user added to groups: spi, gpio"
}

step_udev_rules() {
    log "Fix 2 — udev rules (hardware access for chirpstack user)"

    cat > /etc/udev/rules.d/99-chirpstack-lora.rules <<'EOF'
# ChirpStack LoRaWAN gateway — hardware access rules
KERNEL=="spidev*", GROUP="spi", MODE="0660"
SUBSYSTEM=="gpio", GROUP="gpio", MODE="0660"
EOF

    udevadm control --reload-rules
    udevadm trigger
    info "udev rules written to /etc/udev/rules.d/99-chirpstack-lora.rules"
}

step_postgresql() {
    local db_pass="$1"
    log "Fix 4 — PostgreSQL setup (chirpstack database + pg_trgm)"

    systemctl enable --now postgresql

    sudo -u postgres psql -tc \
        "SELECT 1 FROM pg_roles WHERE rolname='chirpstack'" \
        | grep -q 1 || \
        sudo -u postgres psql -c \
            "CREATE ROLE chirpstack WITH LOGIN PASSWORD '${db_pass}';"
    sudo -u postgres psql -c \
        "ALTER ROLE chirpstack PASSWORD '${db_pass}';"

    sudo -u postgres psql -tc \
        "SELECT 1 FROM pg_database WHERE datname='chirpstack'" \
        | grep -q 1 || \
        sudo -u postgres createdb -O chirpstack chirpstack

    sudo -u postgres psql -d chirpstack \
        -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
    sudo -u postgres psql -d chirpstack \
        -c "CREATE EXTENSION IF NOT EXISTS hstore;"

    info "Database 'chirpstack' ready with pg_trgm and hstore"
}

step_redis() {
    log "Redis"
    sed -i \
        -e 's/^bind .*/bind 127.0.0.1 ::1/' \
        -e 's/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/' \
        /etc/redis/redis.conf
    systemctl enable --now redis-server
    info "Redis bound to 127.0.0.1"
}

step_mosquitto() {
    local mqtt_pass="$1"
    log "Mosquitto MQTT broker"

    cat > /etc/mosquitto/conf.d/chirpstack.conf <<'EOF'
listener 1883 127.0.0.1
allow_anonymous false
password_file /etc/mosquitto/chirpstack.passwd
EOF

    mosquitto_passwd -c -b /etc/mosquitto/chirpstack.passwd chirpstack "$mqtt_pass"
    chown mosquitto:mosquitto /etc/mosquitto/chirpstack.passwd
    chmod 640 /etc/mosquitto/chirpstack.passwd
    systemctl enable --now mosquitto
    info "Mosquitto listening on 127.0.0.1:1883 with authentication"
}

# Fix 5 — SX130x hardware reset script
# POWER_EN (gpiochip4:3, header pin 12) must be held HIGH to power the TCXO.
# Without it, the chip returns version 0x00 and RF calibration always fails.
# NRESET (gpiochip4:22, header pin 11) is owned exclusively by concentratord
# via sx1301_reset_chip/sx1301_reset_pin — do NOT daemonize it here.
step_reset_script() {
    local chip_label="$1"
    log "Fix 5 — SX130x GPIO reset helper (POWER_EN + NRESET)"

    cat > /usr/local/sbin/sx130x-reset.sh <<EOF
#!/usr/bin/env bash
# ${chip_label} hardware reset — Rock Pi 4B+ with Nebra LoRa HAT
#
# POWER_EN : header pin 12 = GPIO4_A3 = gpiochip4 line 3  = sysfs GPIO 131
# NRESET   : header pin 11 = GPIO4_C6 = gpiochip4 line 22 = sysfs GPIO 150
#
# IMPORTANT — GL5712-UX SX1301 has an inverter on NRESET:
#   HIGH = reset ASSERTED (chip held in reset, SPI returns 0x00)
#   LOW  = reset released (chip running)
#
# Therefore: ONLY hold POWER_EN here. NRESET is owned exclusively by
# concentratord via sx1301_reset_chip/sx1301_reset_pin in concentratord.toml.
# Daemonizing NRESET HIGH from here would permanently hold the chip in reset.

set -e

CHIP="${RESET_CHIP}"
POWER_LINE=${POWER_EN_LINE}
POWER_SYSFS=${POWER_EN_GPIO_SYSFS}

if command -v gpioset >/dev/null 2>&1; then
    # Kill any existing POWER_EN daemon
    pkill -f "gpioset -c \${CHIP} --daemonize" 2>/dev/null || true
    sleep 0.05

    # Assert POWER_EN HIGH and hold (powers the TCXO on the LoRa module)
    gpioset -c "\$CHIP" --daemonize "\${POWER_LINE}=1"
    sleep 0.5
else
    # sysfs fallback — POWER_EN only
    echo "\$POWER_SYSFS" > /sys/class/gpio/export 2>/dev/null || true
    echo "out" > "/sys/class/gpio/gpio\${POWER_SYSFS}/direction"
    echo 1 > "/sys/class/gpio/gpio\${POWER_SYSFS}/value"
    sleep 0.5
fi
EOF

    chmod 750 /usr/local/sbin/sx130x-reset.sh
    info "Reset script written to /usr/local/sbin/sx130x-reset.sh"

    # Create the systemd service that runs the reset script at boot
    cat > /etc/systemd/system/chirpstack-lora-power.service <<'SVCEOF'
[Unit]
Description=Hold Nebra LoRa HAT POWER_EN high (SX130x power sequencing)
Before=chirpstack-concentratord-sx1301.service
Before=chirpstack-concentratord-sx1302.service

[Service]
Type=oneshot
RemainAfterExit=yes
# KillMode=none: prevents systemd killing the gpioset daemon when the
# oneshot script exits — the daemon must survive to hold POWER_EN HIGH
KillMode=none
ExecStart=/usr/local/sbin/sx130x-reset.sh
ExecStop=-/usr/bin/pkill -f "gpioset.*gpiochip4.*--daemonize"

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable chirpstack-lora-power.service
    info "chirpstack-lora-power.service created and enabled"
}

step_concentratord_config() {
    local chip_type="$1"
    local model spi_note

    case "$chip_type" in
        sx1302)
            model="rak_2287"
            spi_note="SX1302 + SX1250 radio front-end (RAK2287 / Nebra HAT rev >= 3)"
            ;;
        sx1301)
            model="rak_2245"
            spi_note="SX1301 + SX1257 radio front-end (GL5712-UX / Nebra HAT rev <= 2)"
            ;;
    esac

    log "Concentratord config (${chip_type^^}, model=${model})"

    local conf_dir="/etc/chirpstack-concentratord-${chip_type}"
    mkdir -p "$conf_dir"

    cat > "${conf_dir}/concentratord.toml" <<EOF
# chirpstack-concentratord-${chip_type} — Rock Pi 4B+ / Nebra LoRa HAT / EU868
# Concentrator : ${spi_note}
# Channel plan  : defined in channels.toml (installed by package)

[concentratord]
  log_level = "INFO"

  [concentratord.api]
    event_bind   = "ipc:///tmp/concentratord_event"
    command_bind = "ipc:///tmp/concentratord_command"

[gateway]
  lorawan_public = true
  model          = "${model}"
  region         = "EU868"
  gateway_id     = "${GATEWAY_EUI}"
  com_dev_path   = "${SPI_DEV}"
$(if [ "${chip_type}" = "sx1301" ]; then cat <<SX1301_RESET
  # SX1301/GL5712-UX: concentratord must own NRESET (gpiochip4:22).
  # The GL5712-UX has an inverter on NRESET so the power service must NOT
  # hold this line — concentratord pulses it correctly via these settings.
  sx1301_reset_chip = "/dev/gpiochip4"
  sx1301_reset_pin  = 22
SX1301_RESET
fi)
EOF

    info "Concentratord config written to ${conf_dir}/concentratord.toml"
}

# mqtt-forwarder replaces gateway-bridge for concentratord ZMQ backend
step_mqtt_forwarder() {
    local mqtt_pass="$1"
    log "MQTT Forwarder (concentratord ZMQ -> Mosquitto MQTT)"

    cat > /etc/chirpstack-mqtt-forwarder/chirpstack-mqtt-forwarder.toml <<EOF
# chirpstack-mqtt-forwarder — connects concentratord ZMQ to MQTT broker

[backend]
  enabled = "concentratord"

  [backend.concentratord]
    event_url   = "ipc:///tmp/concentratord_event"
    command_url = "ipc:///tmp/concentratord_command"

[mqtt]
  topic_prefix = "${REGION}"
  server       = "tcp://127.0.0.1:1883"
  username     = "chirpstack"
  password     = "${mqtt_pass}"
EOF

    info "MQTT forwarder config written"
}

step_chirpstack_server() {
    local db_pass="$1" mqtt_pass="$2" api_secret="$3"
    log "ChirpStack v4 network server"

    mkdir -p /etc/chirpstack

    cat > /etc/chirpstack/chirpstack.toml <<EOF
# ChirpStack v4 — single-board gateway/server (Rock Pi 4B+, EU868)

[logging]
  level = "info"
  log_to_syslog = false

[postgresql]
  dsn = "postgres://chirpstack:${db_pass}@127.0.0.1/chirpstack?sslmode=disable"
  max_open_connections = 10
  min_idle_connections = 0

[redis]
  servers = ["redis://127.0.0.1/"]
  tls_enabled = false
  cluster = false

[network]
  net_id = "${NET_ID}"
  enabled_regions = ["${REGION}"]

[api]
  bind   = "0.0.0.0:8080"
  secret = "${api_secret}"

[gateway]
  [gateway.backend]
    [gateway.backend.mqtt]
      server        = "tcp://127.0.0.1:1883"
      username      = "chirpstack"
      password      = "${mqtt_pass}"
      event_topic   = "${REGION}/gateway/+/event/+"
      command_topic = "${REGION}/gateway/{{ .GatewayID }}/command/{{ .CommandType }}"
EOF

    local eu868_conf="/etc/chirpstack/region_eu868.toml"
    if [ ! -f "$eu868_conf" ]; then
        cat > "$eu868_conf" <<'EOF'
[[regions]]
  id = "eu868"
  description = "EU868"
  common_name = "EU868"
EOF
        warn "region_eu868.toml not found from package — wrote minimal stub"
    fi

    info "ChirpStack server config written"
}

step_systemd_overrides() {
    local chip_type="$1"
    log "Fix 3 — Systemd overrides (ZMQ socket cleanup + GPIO pre-reset)"

    local svc=""
    for candidate in \
        "chirpstack-concentratord-${chip_type}" \
        "chirpstack-concentratord" \
        "concentratord-${chip_type}"; do
        systemctl list-unit-files --no-pager 2>/dev/null \
            | grep -q "^${candidate}\.service" && svc="$candidate" && break
    done

    if [ -z "$svc" ]; then
        warn "concentratord service not found — systemd override not applied."
        return
    fi

    local drop_in="/etc/systemd/system/${svc}.service.d/override.conf"
    mkdir -p "$(dirname "$drop_in")"
    cat > "$drop_in" <<EOF
# ChirpStack concentratord — Rock Pi 4B+ / Nebra LoRa HAT overrides

[Unit]
Requires=chirpstack-lora-power.service
After=chirpstack-lora-power.service

[Service]
# Clear any inherited ExecStartPre entries first
ExecStartPre=
# Fix 3: Remove stale ZMQ sockets before start (EADDRINUSE prevention)
ExecStartPre=-/bin/rm -f /tmp/concentratord_event /tmp/concentratord_command
# Create spidev0.0 symlink (some HAL builds default to /dev/spidev0.0)
ExecStartPre=+/bin/ln -sfn /dev/spidev1.0 /dev/spidev0.0
# Wait 3s for chip to settle after POWER_EN assert (prevents lgw_start race)
ExecStartPre=/bin/sleep 3
# Auto-restart delay — gives chip time to fully reset before retry
RestartSec=10
EOF

    systemctl daemon-reload
    info "Systemd override written to ${drop_in}"
}

step_enable_services() {
    local conc_svc="$1"
    log "Enabling services"

    # Core services — enable and start now (no hardware dependency)
    for svc in postgresql redis-server mosquitto chirpstack chirpstack-mqtt-forwarder; do
        systemctl enable "$svc" 2>/dev/null && info "Enabled: $svc" || true
    done

    # Ensure gateway-bridge is disabled (mqtt-forwarder replaces it)
    systemctl disable chirpstack-gateway-bridge 2>/dev/null || true
    systemctl stop chirpstack-gateway-bridge 2>/dev/null || true
    info "chirpstack-gateway-bridge disabled (replaced by chirpstack-mqtt-forwarder)"

    # concentratord: enable but don't start — needs /dev/spidev1.0 (post-reboot)
    if systemctl list-unit-files --no-pager 2>/dev/null \
            | grep -q "^${conc_svc}\.service"; then
        systemctl enable "$conc_svc" 2>/dev/null && \
            info "Enabled (will start after reboot): ${conc_svc}" || true
    fi

    log "Starting non-hardware services now"
    systemctl restart postgresql redis-server mosquitto
    systemctl restart chirpstack-mqtt-forwarder && \
        info "chirpstack-mqtt-forwarder started" || true
    systemctl restart chirpstack && info "chirpstack server started" || \
        warn "chirpstack server failed — check 'journalctl -u chirpstack -n 50'"
}

# =============================================================================
# Argument parsing
# =============================================================================

CHIP_TYPE=""
NON_INTERACTIVE=false

for arg in "$@"; do
    case "$arg" in
        --sx1302)   CHIP_TYPE="sx1302" ;;
        --sx1301)   CHIP_TYPE="sx1301" ;;
        --yes|-y)   NON_INTERACTIVE=true ;;
        --help|-h)
            head -40 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown argument: ${arg}  (use --help)" ;;
    esac
done

# =============================================================================
# Main
# =============================================================================

check_root

MAC=$(derive_gateway_eui)
MAC_HEX=$(tr -d ':' <<< "$MAC")
GATEWAY_EUI="${MAC_HEX:0:6}fffe${MAC_HEX:6:6}"
GATEWAY_EUI_FMT=$(sed 's/../&:/g; s/:$//' <<< "$GATEWAY_EUI")

if [ -z "$CHIP_TYPE" ]; then
    echo -e "\n${BOLD}Detecting concentrator chip type...${RESET}"
    CHIP_TYPE=$(detect_concentrator_hw)

    if [ -n "$CHIP_TYPE" ]; then
        echo -e "    ${GREEN}Auto-detected: ${CHIP_TYPE^^}${RESET}"
    else
        echo -e "    ${YELLOW}Could not auto-detect.${RESET}"
        if $NON_INTERACTIVE; then
            CHIP_TYPE="sx1302"
            echo -e "    Non-interactive mode: defaulting to ${BOLD}SX1302${RESET}"
        else
            echo
            echo "  Which module do you have?"
            echo "    1) SX1302  (RAK2287 — has LEDs; newer Nebra HAT)"
            echo "    2) SX1301  (GL5712-UX or RAK2245 — no LEDs; older Nebra HAT)"
            echo
            read -r -t 30 -p "  Enter 1 or 2 [default: 1 / SX1302 in 30 s]: " choice || true
            case "${choice:-1}" in
                2) CHIP_TYPE="sx1301" ;;
                *) CHIP_TYPE="sx1302" ;;
            esac
        fi
    fi
fi

case "$CHIP_TYPE" in
    sx1302)
        CONC_SVC="chirpstack-concentratord-sx1302"
        CHIP_LABEL="SX1302"
        ;;
    sx1301)
        CONC_SVC="chirpstack-concentratord-sx1301"
        CHIP_LABEL="SX1301"
        ;;
    *) die "Invalid chip type '${CHIP_TYPE}' — use --sx1302 or --sx1301" ;;
esac

mkdir -p /etc/chirpstack
chmod 700 /etc/chirpstack

if [ -f "$STATE_FILE" ]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
    info "Loaded existing credentials from ${STATE_FILE}"
else
    DB_PASS=$(openssl rand -hex 16)
    MQTT_PASS=$(openssl rand -hex 16)
    API_SECRET=$(openssl rand -base64 32 | tr -d '+/=')
    cat > "$STATE_FILE" <<EOF
# ChirpStack setup state — do not edit manually
DB_PASS=${DB_PASS}
MQTT_PASS=${MQTT_PASS}
API_SECRET=${API_SECRET}
GATEWAY_EUI=${GATEWAY_EUI}
CHIP_TYPE=${CHIP_TYPE}
EOF
    chmod 600 "$STATE_FILE"
    info "Generated new credentials -> ${STATE_FILE}"
fi

cat <<PLAN

${BG_RED}${WHITE}${BOLD}                                                                        ${RESET}
${BG_RED}${WHITE}${BOLD}   ██╗      ██████╗ ██████╗  █████╗ ██╗    ██╗ █████╗ ███╗   ██╗      ${RESET}
${BG_RED}${WHITE}${BOLD}   ██║     ██╔═══██╗██╔══██╗██╔══██╗██║    ██║██╔══██╗████╗  ██║      ${RESET}
${BG_RED}${WHITE}${BOLD}   ██║     ██║   ██║██████╔╝███████║██║ █╗ ██║███████║██╔██╗ ██║      ${RESET}
${BG_RED}${WHITE}${BOLD}   ██║     ██║   ██║██╔══██╗██╔══██║██║███╗██║██╔══██║██║╚██╗██║      ${RESET}
${BG_RED}${WHITE}${BOLD}   ███████╗╚██████╔╝██║  ██║██║  ██║╚███╔███╔╝██║  ██║██║ ╚████║      ${RESET}
${BG_RED}${WHITE}${BOLD}   ╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═══╝      ${RESET}
${BG_RED}${WHITE}${BOLD}                                                                        ${RESET}
${BG_DARK}${CYAN}${BOLD}        ChirpStack LoRaWAN Gateway Setup by Mowax                      ${RESET}
${BG_DARK}${CYAN}        Rock Pi 4B+  •  Nebra Indoor LoRa HAT  •  EU868                  ${RESET}
${BG_DARK}${CYAN}                                                                        ${RESET}

${BOLD}${GREEN}ChirpStack LoRaWAN Gateway Setup${RESET}
  Concentrator : ${BOLD}${CHIP_LABEL}${RESET}  (${CONC_SVC})
  Gateway EUI  : ${BOLD}${GATEWAY_EUI_FMT}${RESET}  (from MAC ${MAC})
  Region       : EU868   Net-ID: ${NET_ID}
  SPI device   : ${SPI_DEV}  (active after reboot)
  POWER_EN     : ${RESET_CHIP} line ${POWER_EN_LINE}  (GPIO4_A3, header pin 12)
  NRESET       : ${RESET_CHIP} line ${RESET_LINE}  (GPIO4_C6, header pin 11)

PLAN

if ! $NON_INTERACTIVE; then
    read -r -t 10 -p "  Proceed? [Y/n]: " confirm || true
    case "${confirm:-Y}" in
        [Nn]*) echo "Aborted."; exit 0 ;;
    esac
fi

step_fix_clock
step_fix_armbian_repos
step_spi_overlay
step_install_packages     "$CHIP_TYPE"
step_user_groups
step_udev_rules
step_postgresql           "$DB_PASS"
step_redis
step_mosquitto            "$MQTT_PASS"
step_reset_script         "$CHIP_LABEL"
step_concentratord_config "$CHIP_TYPE"
step_mqtt_forwarder       "$MQTT_PASS"
step_chirpstack_server    "$DB_PASS" "$MQTT_PASS" "$API_SECRET"
step_systemd_overrides    "$CHIP_TYPE"
step_enable_services      "$CONC_SVC"

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

cat <<SUMMARY

${BOLD}+----------------------------------------------------------------------+
|           ChirpStack Setup Complete -- REBOOT REQUIRED              |
+----------------------------------------------------------------------+${RESET}
  Concentrator : ${CHIP_LABEL}  (${CONC_SVC})
  Gateway EUI  : ${GATEWAY_EUI_FMT}
  Region       : EU868

  Credentials saved to: ${STATE_FILE}
  DB password  : ${DB_PASS}
  MQTT password: ${MQTT_PASS}
${BOLD}+----------------------------------------------------------------------+
|  Next steps                                                        |
+----------------------------------------------------------------------+${RESET}
  1. Reboot:
       sudo reboot

  2. After reboot, verify:
       ls -la /dev/spidev1.0
       journalctl -u ${CONC_SVC} -f

  3. Open ChirpStack UI:
       http://${HOST_IP:-<board-ip>}:8080
       Login: admin / admin  — change this immediately!

  4. Register your gateway:
       Gateways -> Add gateway
       EUI: ${GATEWAY_EUI_FMT}
       Region: EU868

${BOLD}+----------------------------------------------------------------------+
|  Diagnostics                                                       |
+----------------------------------------------------------------------+${RESET}
  journalctl -u ${CONC_SVC} -f
  journalctl -u chirpstack-mqtt-forwarder -f
  journalctl -u chirpstack -f
  sudo ps aux | grep gpioset   # verify POWER_EN and NRESET daemons running
${BOLD}+----------------------------------------------------------------------+${RESET}

SUMMARY
