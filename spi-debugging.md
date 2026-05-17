# SPI Debugging — Rock Pi 4B+ / Nebra HAT

This document covers the SPI enablement journey on Armbian Trixie (kernel 6.18) with a Rock Pi 4B+. It took several sessions to get `/dev/spidev1.0` reliably appearing and communicating with the concentrator.

---

## The Problem

On Armbian Trixie rolling builds for the Rock Pi 4B+, the overlay system does not work. Adding overlay entries to `/boot/armbianEnv.txt` produces no result — no errors, nothing in `dmesg`, no devices created. The overlays are silently ignored.

Additionally, the official `rockchip-rk3399-spi-spidev.dtbo` overlay file has `status = disabled` inside it, meaning it would never enable SPI even if it had loaded correctly.

---

## Solution 1: Armbian Overlay (Current — Works on Newer Builds)

The `setup.sh` script uses the `rk3399-spi-spidev` overlay, which works correctly on current Armbian builds:

```
overlays=rk3399-spi-spidev
param_spidev_spi_bus=1
param_spidev_max_freq=2000000
```

This creates `/dev/spidev1.0` after reboot. If this works for you, you're done — no DTB editing needed.

---

## Solution 2: Direct DTB Editing (Fallback for Older Kernels)

If the overlay approach fails (no `/dev/spidev1.0` after reboot), edit the Device Tree Blob directly.

### Step 1: Decompile the DTB

```bash
dtc -I dtb -O dts \
    /boot/dtb/rockchip/rk3399-rock-pi-4b-plus.dtb \
    2>/dev/null > /boot/rockpi4bplus.dts
```

### Step 2: Edit the SPI1 block

Find the `spi@ff1d0000` block in the DTS. It will look like:

```
spi@ff1d0000 {
    status = "disabled";
    ...
};
```

Change it to:

```
spi@ff1d0000 {
    status = "okay";
    num-cs = <3>;
    #address-cells = <1>;
    #size-cells = <0>;

    spidev@0 {
        compatible = "linux,spidev";
        reg = <0>;
        spi-max-frequency = <2000000>;
    };
};
```

> **Why `num-cs = <3>`?**  
> The Nebra HAT wires the mPCIe module to SPI chip select 2 (CS2), not CS0. Without `num-cs = <3>`, the SPI controller only exposes CS0 and CS1. Adding CS2 requires telling the controller 3 chip selects exist.

### Step 3: Recompile

```bash
dtc -I dts -O dtb \
    -o /boot/dtb/rockchip/rk3399-rock-pi-4b-plus.dtb \
    /boot/rockpi4bplus.dts 2>/dev/null
```

### Step 4: Reboot and verify

```bash
reboot
ls /dev/spi*
# Should show: /dev/spidev1.0  /dev/spidev1.2
```

---

## SPI Device Mapping

| Device | CS | What it connects to |
|---|---|---|
| `/dev/spidev1.0` | CS0 | Used by `chirpstack-concentratord` (via symlink) |
| `/dev/spidev1.2` | CS2 | Nebra HAT mPCIe slot (hardware wiring) |

The `setup.sh` creates a symlink in the systemd override:

```
ExecStartPre=+/bin/ln -sfn /dev/spidev1.0 /dev/spidev0.0
```

This covers HAL builds that default to `/dev/spidev0.0`.

---

## SPI NOR Flash Recall

All Nebra Rock Pi units had a SPI NOR flash chip (`XT25F32BWIG`, 32Mbit, 8-pin SOIC) physically removed as part of a product recall. The chip sat on **SPI bus 1** — the same bus used for the LoRa concentrator.

The bare pads left by the removal create unterminated stub traces on SPI1. This causes:

- Signal reflections on MOSI/MISO/CLK
- Write transactions corrupted at high speeds
- Reads partially functional (concentrator drives MISO strongly enough to overcome reflections)
- Speed sensitivity — behaviour changes between 125kHz, 250kHz, 2MHz

**This is why SPI speed is set to 2MHz in the script, not the default 8–16MHz.**

The Nebra firmware on the original balenaOS stack works despite this recall because it also runs at reduced SPI speed with specific initialisation sequencing — confirmed by extracting and comparing the Nebra firmware source.

---

## GL5712-UX Chip Select Discovery

Research into the Nebra firmware source code revealed that the HAT uses **chip select 2** (`spidev1.2`), not CS0. The mPCIe module is wired to CS2 on SPI bus 1. This was non-obvious and cost several debugging sessions.

However: `chirpstack-concentratord-sx1301` communicates correctly over `spidev1.0` (CS0). The concentratord handles the SPI mux format internally (`[0x00, addr, dummy]` 3-byte protocol). The CS2 wiring is relevant to the legacy packet forwarder approach, not concentratord.

---

## Testing SPI Communication

### Verify the device exists

```bash
ls -la /dev/spidev1.0
spi-config -d /dev/spidev1.0 -q
```

### Check concentratord can see the chip

```bash
journalctl -u chirpstack-concentratord-sx1301 -n 20 --no-pager
# Look for: lgw_start succeeded
# Or: Publishing stats event (means it's working)
```

### Check POWER_EN is held

```bash
ps aux | grep gpioset
# Should show: gpioset -c gpiochip4 --daemonize 3=1
```
