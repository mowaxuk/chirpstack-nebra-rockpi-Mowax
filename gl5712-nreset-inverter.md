# GL5712-UX NRESET Inverter — The Critical Discovery

This is the single most important thing to understand about the Nebra HAT with the GL5712-UX concentrator module. Getting this wrong causes the chip to appear permanently dead — SPI returns `0x00` for everything, `lgw_start` fails, and no amount of software debugging helps.

---

## The Hardware

The GL5712-UX is a third-party SX1301-based concentrator module made by MAXIIOT. It is found in the older Nebra Indoor LoRa HAT (the one with no status LEDs on the mPCIe card).

Unlike the standard Semtech SX1301 reference design, the GL5712-UX has a **hardware inverter on the NRESET line**.

---

## What the Inverter Does

```
Standard SX1301 logic:
  NRESET HIGH = reset RELEASED = chip running
  NRESET LOW  = reset ASSERTED = chip in reset

GL5712-UX logic (INVERTED):
  NRESET HIGH = reset ASSERTED = chip stuck in reset  ← BACKWARDS
  NRESET LOW  = reset RELEASED = chip running
```

If anything holds NRESET HIGH — including a GPIO daemon, a service, or even leaving the pin floating in a pulled-up state — the chip is permanently in reset. SPI communication appears to partially work (you may see non-zero reads for some registers) but the MCU never starts, `cal_status` returns `0x00`, and `lgw_start` fails.

---

## How This Manifests

You'll see one or more of these symptoms:

```
# concentratord logs
ERROR: lgw_start failed

# SPI returns 0x00 for everything
# cal_status = 0x00
# fw_version = 0x00

# Or the chip appears to respond but calibration never completes
```

---

## The Fix

**POWER_EN and NRESET must be handled separately and by different owners.**

### POWER_EN (gpiochip4 line 3 / header pin 12)

Must be held HIGH for the chip's TCXO to run. This is done by the `chirpstack-lora-power` systemd service via a daemonized `gpioset`:

```bash
gpioset -c gpiochip4 --daemonize 3=1
```

The service uses `KillMode=none` so the daemon survives after the oneshot script exits.

### NRESET (gpiochip4 line 22 / header pin 11)

**Must NOT be touched by the power service.** It is owned exclusively by `chirpstack-concentratord` via these settings in `concentratord.toml`:

```toml
sx1301_reset_chip = "/dev/gpiochip4"
sx1301_reset_pin  = 22
```

`concentratord` pulses NRESET correctly for the GL5712-UX because the `rak_2245` model it uses internally handles the reset sequence in a way that works with this hardware.

---

## What Happens if You Get It Wrong

### Scenario A: NRESET is daemonized HIGH (worst case)

```bash
# WRONG — permanently holds chip in reset
gpioset -c gpiochip4 --daemonize 3=1 22=1
```

Result: chip never comes out of reset. SPI returns `0x00`. Looks identical to a completely dead module.

### Scenario B: NRESET left floating

Depending on pull-up resistors on the HAT PCB, the chip may or may not come out of reset randomly. Behaviour is inconsistent across power cycles.

### Scenario C: Correct — POWER_EN only in daemon, NRESET to concentratord

```bash
# CORRECT — daemon holds POWER_EN only
gpioset -c gpiochip4 --daemonize 3=1

# concentratord.toml handles NRESET via:
# sx1301_reset_chip = "/dev/gpiochip4"
# sx1301_reset_pin  = 22
```

Result: `lgw_start` succeeds, stats events appear in logs, gateway comes online.

---

## Cold Boot Requirement

Even with the correct GPIO setup, rapid warm reboots can leave the GL5712-UX in an indeterminate state. The chip needs a clean power cycle to initialise correctly.

After any setup or service failure:

```bash
poweroff
# Physically unplug the power cable
# Wait 10 seconds
# Plug back in
```

The `ExecStartPre=/bin/sleep 3` in the concentratord systemd override gives the chip time to settle after POWER_EN is asserted before concentratord attempts SPI communication.

---

## GPIO Reference

| Signal | Header Pin | GPIO Bank | gpiochip4 Line | sysfs GPIO |
|---|---|---|---|---|
| POWER_EN | Pin 12 | GPIO4_A3 | 3 | 131 |
| NRESET | Pin 11 | GPIO4_C6 | 22 | 150 |

---

## Verifying Correct Operation

```bash
# Check POWER_EN is held (should show gpioset daemon)
ps aux | grep gpioset
# Expected: gpioset -c gpiochip4 --daemonize 3=1

# Check concentratord is running
systemctl status chirpstack-concentratord-sx1301

# Check for successful start in logs
journalctl -u chirpstack-concentratord-sx1301 -n 30 --no-pager
# Look for: Publishing stats event, rx_received: N
# (rx_received incrementing means the chip is receiving RF packets)
```

---

## Summary

| | POWER_EN | NRESET |
|---|---|---|
| **Owner** | `chirpstack-lora-power` service | `chirpstack-concentratord` |
| **Method** | `gpioset --daemonize` | `sx1301_reset_pin` in TOML |
| **State** | Always HIGH | Pulsed by concentratord at startup |
| **If wrong** | Chip unpowered, SPI dead | Chip stuck in reset, SPI returns 0x00 |
