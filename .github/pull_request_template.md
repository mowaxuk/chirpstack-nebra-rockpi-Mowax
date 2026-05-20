## What does this PR do?

<!-- One or two sentences describing the change. -->

## Type of change

- [ ] Bug fix
- [ ] New hardware support
- [ ] Documentation / build diary entry
- [ ] Config or GPIO change
- [ ] Other — describe:

## Hardware tested on

<!-- This is the most important section. Without hardware details it's very hard to review changes safely. -->

| Component | Detail |
|---|---|
| SBC | e.g. Radxa Rock Pi 4B+ |
| OS | e.g. Armbian Trixie, kernel 6.18 |
| Concentrator | e.g. GL5712-UX (SX1301) / RAK2287 (SX1302) |
| Frequency | e.g. EU868 |

## Testing done

- [ ] Cold power cycle performed after setup (not just reboot)
- [ ] `journalctl -u chirpstack-concentratord-sx1301 -f` shows `Publishing stats event`
- [ ] `/dev/spidev1.0` present after reboot
- [ ] ChirpStack UI accessible at `:8080`
- [ ] Tested with `--sx1301` flag
- [ ] Tested with `--sx1302` flag
- [ ] `bash -n setup.sh` syntax check passed (if `setup.sh` was modified)

_Tick only what applies. If you couldn't test something, explain why below._

## Anything else?

<!-- Known limitations, follow-up work needed, or context that helps review. -->
