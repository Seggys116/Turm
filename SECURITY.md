# Security

Turm is maintained by one person, so only the latest release gets fixes. Updates ship through the app's built-in updater.

## Reporting a vulnerability

Please don't open a public issue. Use [Report a vulnerability](https://github.com/Seggys116/Turm/security/advisories/new) on the Security tab instead, which keeps the report private until a fix is out.

Include the Turm version, your macOS or iOS version, and the steps to reproduce. I'll reply as soon as I can.

The parts most worth a look are Remote Access (the Mac serving its shells to the iOS app), pairing, SSH and stored keys, and iCloud sync. [docs/remote-access.md](docs/remote-access.md) describes the security model.
