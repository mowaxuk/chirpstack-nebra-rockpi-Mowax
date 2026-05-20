# Security policy

## Supported versions

This project is a single-branch setup script targeting a specific hardware and OS combination. Only the current `main` branch is actively maintained.

| Branch | Supported |
|--------|-----------|
| `main` | ✅ Yes |
| Older commits | ❌ No |

## What counts as a security issue

Given what `setup.sh` does, the following are worth reporting privately:

- Insecure credential generation (API keys, MQTT passwords, database passwords)
- Config files written with world-readable permissions that contain secrets
- Anything in `/etc/chirpstack/.setup-state` that could leak credentials
- Shell injection or unsafe variable handling in `setup.sh`
- Mosquitto or ChirpStack being configured in a way that exposes services to the network unintentionally
- Default credentials not being flagged clearly enough to the user

If you're unsure whether something is a security issue, err on the side of reporting it privately — better safe than a public issue.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Instead, report it privately via [GitHub's private vulnerability reporting](https://github.com/mowaxuk/chirpstack-nebra-rockpi-Mowax/security/advisories/new) or by contacting the maintainer directly through GitHub.

Include:

- A description of the vulnerability
- Steps to reproduce it
- What you think the impact could be
- Your suggested fix, if you have one

You'll get a response within a few days. If a fix is needed, it will be released before any public disclosure.

## Out of scope

The following are not considered security issues for this project:

- ChirpStack application-layer vulnerabilities (report those to the [ChirpStack project](https://github.com/chirpstack/chirpstack))
- Armbian or kernel vulnerabilities (report those upstream)
- Issues caused by running the script on unsupported hardware or OS versions
- The default `admin`/`admin` ChirpStack credentials — the script flags this clearly and it's the user's responsibility to change them
