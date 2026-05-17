# Hardware Notes — Rock Pi 4B+ / Nebra LoRa HAT

---

## Rock Pi 4B+ 40-Pin Header (LoRa-relevant pins)

```
Pin 11  GPIO4_C6  gpiochip4:22  sysfs 150  →  NRESET (GL5712-UX, via HAT)
Pin 12  GPIO4_A3  gpiochip4:3   sysfs 131  →  POWER_EN (HAT TCXO power)
Pin 19  SPI1_TXD  (MOSI)
Pin 21  SPI1_RXD  (MISO)
Pin 23  SPI1_CLK  (CLK)
Pin 24  SPI1_CS0  →  /dev/spidev1.0
Pin 26  SPI1_CS1  →  /dev/spidev1.1
```

> Note: The Nebra HAT routes the mPCIe slot to CS2 in hardware, but
> `chirpstack-concentratord` communicates correctly via CS0 (`spidev1.0`).

---

## Nebra Indoor LoRa HAT

The HAT does not contain the LoRa chip directly. It has a Mini PCIe (mPCIe) slot that accepts a LoRa concentrator module. Two modules have been used in different Nebra HAT revisions:

| Module | Chip | LEDs | Notes |
|---|---|---|---|
| GL5712-UX (MAXIIOT) | SX1301 + SX1257 | None | Older HAT. Has NRESET inverter — see [gl5712-nreset-inverter.md](gl5712-nreset-inverter.md) |
| RAK2287 | SX1302 + SX1250 | Green + Red | Newer HAT. Standard reset logic. |

**Identifying your module:** Remove the mPCIe card from the HAT slot and read the label on the PCB.

The FCC ID `2ARPP-GL5712UX` on the Nebra unit's compliance label refers to the product enclosure, **not** the concentrator module. The diagnostics endpoint can misreport the module type — inspect the physical card.

---

## SPI NOR Flash Recall

All Nebra Rock Pi Indoor Hotspot units shipped with or had subsequently applied a modification: the `XT25F32BWIG` SPI NOR flash chip was removed from the Rock Pi 4B+ PCB.

| Detail | Value |
|---|---|
| Chip | XT25F32BWIG (XTX 32Mbit SPI NOR flash) |
| Package | 8-pin SOIC |
| SPI bus | SPI1 — same bus as the LoRa concentrator |
| Effect | Bare pads leave unterminated stub traces on SPI1 |

The stub traces cause signal reflections that affect write reliability at high SPI speeds. This is why the setup script uses 2MHz rather than the default 8–16MHz.

**This affects every Nebra Rock Pi Indoor Hotspot.** If you sourced your Rock Pi from a Nebra unit or from eBay as a used Nebra part, assume the chip has been removed.

---

## SX1301 vs SX1302 Differences

| | SX1301 (GL5712-UX) | SX1302 (RAK2287) |
|---|---|---|
| concentratord package | `chirpstack-concentratord-sx1301` | `chirpstack-concentratord-sx1302` |
| In ChirpStack APT repo | No — must download from artifacts.chirpstack.io | Yes |
| NRESET logic | **Inverted** — HIGH = reset | Normal — LOW = reset |
| POWER_EN required | Yes | Yes |
| Model string in TOML | `rak_2245` | `rak_2287` |
| SPI protocol | 3-byte mux: `[0x00, addr, dummy]` | Different |
| Cold boot sensitivity | High — warm reboot often fails | Lower |

---

## Systemd Service Dependencies

```
chirpstack-lora-power.service
    │  (holds POWER_EN HIGH via gpioset daemon, KillMode=none)
    │
    └──> chirpstack-concentratord-sx1301.service
             │  Requires= and After= lora-power
             │  ExecStartPre: sleep 3, clear ZMQ sockets, spidev symlink
             │  sx1301_reset_chip/pin owns NRESET
             │
             └──> chirpstack-mqtt-forwarder.service
                      │  ZMQ → MQTT bridge
                      │
                      └──> chirpstack.service
                               │  Network server
                               ├── PostgreSQL
                               └── Redis
```

---

## Credentials

The setup script generates random credentials on first run and saves them to:

```
/etc/chirpstack/.setup-state   (chmod 600)
```

Contents:

```
DB_PASS=<random hex>
MQTT_PASS=<random hex>
API_SECRET=<random base64>
GATEWAY_EUI=<derived from MAC>
CHIP_TYPE=sx1301|sx1302
```

Re-running the script preserves these credentials.

---

## Gateway EUI Derivation

The Gateway EUI is derived from the `end0` (wired Ethernet) MAC address using the EUI-64 method:

```
MAC:  b0:02:47:93:85:cd
EUI:  b00247fffe9385cd
      ^^^^^^      ^^^^
      first 3     last 3 bytes of MAC
            ^^^^
            fffe inserted in middle
```

This matches the standard IEEE EUI-64 format used by LoRaWAN gateways.
