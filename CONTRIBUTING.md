# Contributing to chirpstack-nebra-rockpi

Thanks for wanting to help. This project exists because setting up a ChirpStack v4 gateway on a Rock Pi with a Nebra HAT is genuinely hard, and every documented fix makes it easier for the next person.

Contributions are welcome — whether that's a bug report, a hardware compatibility note, a fix for `setup.sh`, or documentation of a problem you spent days solving.

---

## Before you open an issue or PR

This repo targets a very specific hardware combination:

| Component | Supported |
|---|---|
| SBC | Radxa Rock Pi 4B+ (RK3399) |
| OS | Armbian Trixie (Debian 13, kernel 6.x) |
| HAT | Nebra Indoor LoRa HAT (Pi Supply) |
| Concentrator | GL5712-UX (SX1301) or RAK2287 (SX1302) |
| Frequency | EU868 |

If you're on a different Rock Pi model, a different OS, or a different HAT, the script will likely not work as-is. Issues for unsupported hardware are fine — they may lead to new branches — but please make clear what you're running.

---

## Reporting a bug

Open an issue and include all of the following. Without this, it's almost impossible to reproduce hardware problems.

**System info**
```
uname -a
cat /etc/armbian-release
```

**Concentrator module**
- GL5712-UX (black PCB, "GL5712" or "MAXIIOT" printed, no LEDs)
- RAK2287 (green PCB, green/red LEDs)
- Other — describe it

**SPI device present?**
```
ls -la /dev/spidev*
```

**Service logs**
```
journalctl -u chirpstack-concentratord-sx1301 --no-pager -n 60
journalctl -u chirpstack-concentratord-sx1302 --no-pager -n 60
journalctl -u chirpstack --no-pager -n 40
```

**POWER_EN status**
```
ps aux | grep gpioset
```

**Symptom**
Exact error message or log line. If you're seeing `SPI returns 0x00`, `lgw_start failed`, or `cal_status = 0x00`, say so — those are well-known failure modes with documented causes in this repo.

---

## Contributing a fix or improvement

1. Fork the repo and create a branch from `main`
2. Make your changes
3. Test on real hardware — see the testing section below
4. Open a pull request

### What makes a good PR

- **Shell script changes** — test with both `--sx1301` and `--sx1302` flags if your change touches concentrator detection. Run `bash -n setup.sh` (syntax check) before submitting.
- **Documentation fixes** — typos, clarifications, and additional debugging steps are always welcome. No hardware test needed for docs-only changes.
- **New hardware support** — if you've got a different Rock Pi model or concentrator working, a PR adding a new branch or conditional path is very welcome. Include your hardware details in the PR description and update the hardware table in the README.
- **GPIO / TOML config changes** — explain what broke and what you changed. Reference the relevant section of the README (NRESET inverter, POWER_EN, etc.) if applicable.

### Testing checklist

Before submitting a PR that touches `setup.sh` or any config files, confirm:

- [ ] Cold power cycle performed after setup (not just reboot)
- [ ] `journalctl -u chirpstack-concentratord-sx1301 -f` shows `Publishing stats event` or equivalent
- [ ] `/dev/spidev1.0` present after reboot
- [ ] ChirpStack UI accessible at `:8080`
- [ ] Concentrator module and Armbian version noted in PR description

If you can't test everything (e.g. you only have one HAT model), say so in the PR — partial testing is still useful.

---

## Commit messages

Keep them short and descriptive. No strict convention required, but aim for:

```
fix: hold POWER_EN before concentratord start
docs: add RAK2287 SPI debug steps
feat: auto-detect SX1302 via lspci
```

One logical change per commit. If you're fixing a bug and updating docs for the same fix, that's one commit.

---

## Adding to the build diary

The `docs/` folder is a debugging log, not polished documentation. If you spent hours solving a problem that isn't documented yet, a new `.md` file in `docs/` describing the problem and fix is one of the most valuable contributions you can make.

Format doesn't matter much — just include:
- What the symptom was (exact error/log output)
- What you tried that didn't work
- What actually fixed it
- Your hardware/OS version

---

## Questions

Not sure if something is a bug or a configuration issue? Open a discussion or check:

- [ChirpStack forum](https://support.chirpstack.io) — search "Rock Pi SPI"
- [r/LoRa](https://reddit.com/r/LoRa)
- [The Things Network forum](https://thethingsnetwork.org/forum)

---

## Licence

By contributing, you agree that your contributions will be licensed under the MIT licence, the same as this project.
