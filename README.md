# chirpstack-nebra-rockpi

**One-script ChirpStack v4 LoRaWAN gateway setup for the Radxa Rock Pi 4B+ with a Nebra Indoor LoRa HAT.**

Built and tested by [Mowax](https://github.com/mowaxuk) after several weeks of hardware debugging. This repo exists because getting a Nebra HAT working on a Rock Pi under modern Armbian is genuinely hard — the SPI overlay system is broken, the GL5712-UX concentrator has a non-obvious NRESET inverter, and there are almost no documented solutions for this exact combination.

If you have this hardware and have been staring at `SPI returns 0x00` or `lgw_start failed`, this is for you.

**Keywords:** LoRaWAN gateway, ChirpStack v4, Rock Pi 4B+, Radxa RK3399, Nebra Indoor Hotspot, Nebra LoRa HAT, GL5712-UX, GL5712, MAXIIOT, SX1301, RAK2245, RAK2287, SX1302, Armbian Trixie, EU868, private LoRaWAN network, chirpstack-concentratord-sx1301, chirpstack-concentratord-sx1302, lgw_start failed, SPI returns 0x00, NRESET inverter, gpiochip4, spidev1.0, LoRa gateway Raspberry Pi alternative

---

## Hardware

| Component | Detail |
|---|---|
| Single Board Computer | Radxa Rock Pi 4B+ (RK3399) |
| Operating System | Armbian Trixie (Debian 13, kernel 6.x) |
| LoRa HAT | Nebra Indoor LoRa HAT (Pi Supply) |
| Concentrator module | GL5712-UX (SX1301 + SX1257) — older Nebra HAT |
| OR | RAK2287 (SX1302 + SX1250) — newer Nebra HAT |
| Frequency | EU868 (UK/Europe) |
| Antenna | RP-SMA, 3dBi |

> **Which module do you have?**  
> Look at the mPCIe card in your HAT's slot.  
> - GL5712-UX — black PCB, no status LEDs, says "GL5712" or "MAXIIOT"  
> - RAK2287 — green PCB, has green/red LEDs  
>
> The script auto-detects, or use `--sx1301` / `--sx1302` to force.

---

## Who is this for?

This repo is for anyone who:

- Has a **Nebra Indoor LoRa HAT** (Pi Supply) on a **Rock Pi 4B+** running **Armbian**
- Is trying to run a **private ChirpStack v4 LoRaWAN network server**
- Has hit `lgw_start failed`, `SPI returns 0x00`, or `cal_status = 0x00` and can't find a solution
- Has a **GL5712-UX** (MAXIIOT, SX1301-based, black PCB, no LEDs) or **RAK2287** (SX1302-based, green PCB) concentrator module
- Bought a second-hand **Nebra Rock Pi Indoor Hotspot** from eBay and wants to repurpose it as a private gateway

It also applies to anyone who has a Rock Pi 4B+ where the **SPI NOR flash chip (XT25F32BWIG) was removed** as part of the Nebra product recall — this affects every Nebra Rock Pi unit and causes SPI write failures at high speeds.

---

## Quick Start

```bash
# Flash Armbian Trixie minimal to SD card, boot, SSH in as root, then:

wget https://raw.githubusercontent.com/mowax/chirpstack-nebra-rockpi/main/setup.sh
bash setup.sh
```

After the script completes, **do a full cold power cycle** (not just reboot):

```bash
poweroff
# Unplug power cable, wait 10 seconds, plug back in
```

Then verify:

```bash
journalctl -u chirpstack-concentratord-sx1301 -f
# Should see: Publishing stats event, rx_received: ...
```

Open ChirpStack UI at `http://<your-pi-ip>:8080` — login `admin` / `admin` (change immediately).

---

## What the Script Does

| Step | Action |
|---|---|
| 1 | Fixes system clock (fresh Armbian has no RTC — apt breaks without this) |
| 2 | Disables broken Armbian beta repos, uses Debian stable only |
| 3 | Adds SPI1 overlay to armbianEnv.txt — enables `/dev/spidev1.0` |
| 4 | Installs: PostgreSQL, Redis, Mosquitto, ChirpStack v4, concentratord |
| 5 | Configures udev rules, systemd services, MQTT forwarder |
| 6 | Writes GPIO reset script — holds POWER_EN (gpiochip4:3) HIGH |
| 7 | Writes systemd override — sleep 3 before start, RestartSec=10 |
| 8 | Generates random DB/MQTT/API credentials, saves to `/etc/chirpstack/.setup-state` |
| 9 | Derives Gateway EUI from `end0` MAC address |

Safe to re-run. Credentials are preserved on subsequent runs.

### Options

```bash
bash setup.sh --sx1301    # Force SX1301 (GL5712-UX, older HAT)
bash setup.sh --sx1302    # Force SX1302 (RAK2287, newer HAT)
bash setup.sh --yes       # Non-interactive (no prompts)
```

---

## The Hard Part — Why This Took Weeks

### Problem 1: Armbian SPI overlay system is broken

On Armbian Trixie rolling builds for the Rock Pi 4B+, overlays listed in `/boot/armbianEnv.txt` are silently ignored at boot. No errors, nothing in dmesg — they just don't load.

**Fix:** The script uses the `rk3399-spi-spidev` overlay which does work correctly on current Armbian builds. If you're on a very early kernel and this fails, see [docs/spi-debugging.md](docs/spi-debugging.md) for the direct DTB edit method.

### Problem 2: The GL5712-UX has an inverter on NRESET

**This is the big one.** The GL5712-UX concentrator module has a hardware inverter on its NRESET line:

```
HIGH on NRESET pin = reset ASSERTED = chip stuck in reset = SPI returns 0x00
LOW  on NRESET pin = reset released = chip running
```

This is backwards from the standard Semtech SX1301 reference design. If you hold NRESET HIGH (which is the natural "assert" logic), the chip never comes out of reset. SPI reads return `0x00` for everything.

**Fix:** The `chirpstack-lora-power` service holds **only POWER_EN** (gpiochip4 line 3). NRESET is owned exclusively by `chirpstack-concentratord` via `sx1301_reset_chip`/`sx1301_reset_pin` in the TOML config. Do not daemonize NRESET HIGH — ever.

### Problem 3: Cold boot required

Repeated warm reboots leave the GL5712-UX in an indeterminate state. After setup or after any service problems, always do:

```bash
poweroff        # NOT reboot
# Unplug power, wait 10 seconds, plug back in
```

The `ExecStartPre=/bin/sleep 3` in the systemd override gives the chip settling time after POWER_EN is asserted.

---

## GPIO Reference (Rock Pi 4B+)

| Signal | Header Pin | GPIO | gpiochip4 Line | sysfs GPIO |
|---|---|---|---|---|
| POWER_EN | Pin 12 | GPIO4_A3 | Line 3 | 131 |
| NRESET | Pin 11 | GPIO4_C6 | Line 22 | 150 |

---

## Software Stack

```
LoRa Device
    │ (RF, EU868)
    ▼
Nebra HAT (GL5712-UX / SX1301)
    │ SPI (/dev/spidev1.0)
    ▼
chirpstack-concentratord-sx1301
    │ ZMQ IPC
    ▼
chirpstack-mqtt-forwarder
    │ MQTT (tcp://127.0.0.1:1883)
    ▼
mosquitto
    │ MQTT
    ▼
chirpstack (network server)
    │
    ├── PostgreSQL (device/session storage)
    ├── Redis (cache)
    └── Web UI :8080
```

---

## After Setup

### Register your gateway

1. Open `http://<your-pi-ip>:8080`
2. Login: `admin` / `admin` — **change this password**
3. Go to **Gateways → Add gateway**
4. Enter the EUI shown at the end of the setup script output
5. Select region: **EU868**

### Useful commands

```bash
# Service status
systemctl status chirpstack-concentratord-sx1301
systemctl status chirpstack-mqtt-forwarder
systemctl status chirpstack

# Live logs
journalctl -u chirpstack-concentratord-sx1301 -f
journalctl -u chirpstack -f

# Verify POWER_EN is held
ps aux | grep gpioset

# Check SPI device present (after reboot)
ls -la /dev/spidev1.0
```

---

## Tested On

| Component | Version |
|---|---|
| Armbian | Trixie (Debian 13), kernel 6.18 |
| ChirpStack | v4.x |
| chirpstack-concentratord-sx1301 | 4.7.1 |
| chirpstack-mqtt-forwarder | latest from APT |

---

## Build Diary

The `docs/` folder contains the full debugging story — SPI device tree battles, the GL5712 NRESET inverter discovery, the removed SPI flash chip (Nebra recall), and how it was eventually solved. Worth reading if you're hitting similar problems.

- [docs/spi-debugging.md](docs/spi-debugging.md) — SPI enablement, device tree, chip select issues
- [docs/gl5712-nreset-inverter.md](docs/gl5712-nreset-inverter.md) — The NRESET inverter discovery and fix
- [docs/hardware-notes.md](docs/hardware-notes.md) — GPIO pinout, SPI NOR flash recall, chip differences

---

## Adding your first device

Once the gateway is online, add a LoRaWAN end device in ChirpStack:

1. **Device Profiles → Add** — set LoRaWAN MAC version to match your device (e.g. 1.0.3 for Browan TBOL100), region EU868, OTAA
2. **Applications → Add** — create an application to hold your devices
3. **Add device** — enter DevEUI and JoinEUI, select the profile, submit
4. **OTAA keys tab** — enter the AppKey, submit
5. Power on the device — a `join` event should appear in the Events tab within 60 seconds, followed by the first uplink

### Payload codec

Raw uplinks arrive as hex. Add a JavaScript codec under Device Profiles → Payload codec to decode them into human-readable fields. ChirpStack v4 requires the decode function to return `{ data: decoded }`.

### Visualising GPS data

ChirpStack's built-in map shows gateway location only — it does not plot device GPS tracks. For a GPS tracker, forward the decoded data to an external tool:

| Tool | Notes |
|---|---|
| **Node-RED** | Subscribe to MQTT, parse decoded JSON, plot on a world map node. Runs on the same Rock Pi. |
| **Grafana** | Geomap panel with PostgreSQL or InfluxDB source. Shows historical tracks with time filtering. |
| **Datacake** | Cloud IoT dashboard with free tier and native ChirpStack integration. Map widget plots lat/lon automatically. |
| **InfluxDB + Telegraf** | Telegraf MQTT consumer writes decoded fields to InfluxDB. Pairs with Grafana for long-term storage. |

The MQTT topic for all uplinks is `eu868/gateway/+/event/up`. Decoded fields appear in the `object` key of the payload JSON.

---

## Community

If this helped you, the following places have active threads on Rock Pi / Nebra / ChirpStack issues:

- [Nebra community forums](https://nebra.com/blogs/news)
- [ChirpStack forum](https://forum.chirpstack.io) — search for "Rock Pi SPI"
- [r/LoRa](https://reddit.com/r/LoRa) and [r/homeautomation](https://reddit.com/r/homeautomation)
- [The Things Network forum](https://thethingsnetwork.org/forum)

---

## Licence

MIT
