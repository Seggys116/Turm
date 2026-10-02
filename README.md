<div align="center">

<h1>
  <img src="https://raw.githubusercontent.com/Seggys116/Turm/main/.github/assets/icon.png" alt="" width="72" align="absmiddle" />
  &nbsp;Turm
</h1>

A terminal for macOS, with an iPhone and iPad app that can drive your Mac's shells.

[![CI](https://github.com/Seggys116/Turm/actions/workflows/ci.yml/badge.svg)](https://github.com/Seggys116/Turm/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/Seggys116/Turm)](https://github.com/Seggys116/Turm/releases/latest)

<img src="https://raw.githubusercontent.com/Seggys116/Turm/main/.github/assets/screenshots/mac-hero.png" alt="Turm on macOS with three tiled panes: finished test and git blocks, a build in progress and a Terraform plan" width="900" />

</div>

Turm puts every command and its output in a block with its exit code, duration, folder and git branch, so a long session is easy to scroll back through. It looks at the project in the current folder and puts its build, run and test commands on a bar under the shell. Cargo, SwiftPM, Xcode, Node, Python, Go, CMake, Gradle and several others are recognised, and a [`Turm.json`](docs/turm-json.md) file lets you add your own.

Other things it does:

- Tiling panes, each with its own command history.
- `@folder`, `!command` and `#file` shortcuts that expand as you type.
- SSH with saved hosts and a `>host` quick connect. Blocks, completion and the project bar keep working on the remote machine.
- Kitty graphics, so tools that draw images in the terminal work.
- A Spotlight-style palette for running commands and jumping between shells.
- "Open in Turm" in Finder.

The iOS app connects to Turm on your Mac to list its shells and type into them, over the local network or Tailscale. It can also open SSH sessions on its own. Hosts, shortcuts and keys can sync between devices through iCloud.

<p align="center">
  <img src="https://raw.githubusercontent.com/Seggys116/Turm/main/.github/assets/screenshots/ios.png" alt="The iPhone app: the sidebar with sessions, a paired Mac and SSH hosts; a build running in a Mac shell; and an SSH session" width="900" />
</p>

## Install

Download the disk image from the [latest release](https://github.com/Seggys116/Turm/releases/latest). It needs macOS 26 on Apple silicon, and updates itself after that. Remote Access for the iOS app, iCloud sync and per-pane history are on `main` and ship in 1.4.0.

The iOS app is coming to the App Store with 1.4.0. Until then you can build it from source. It needs iOS 18.

## Building

Requires macOS, Xcode and Node.js.

```
git clone https://github.com/Seggys116/Turm.git
cd Turm
npm ci --prefix Icons
open Turm.xcodeproj
```

The build fails until `npm ci --prefix Icons` has been run. It installs the pinned [Simple Icons](https://simpleicons.org) and [Lobe Icons](https://github.com/lobehub/lobe-icons) packages that the sidebar and project bar use for program and ecosystem logos, and generates `Icons/inputs.xcfilelist`, which lists the files the build phase may read. `Icons/manifest.json` lists the glyphs that are copied into the app at build time, and the build refuses any icon whose licence does not allow redistribution. Run `npm ci --prefix Icons` again after editing `Icons/manifest.json`.

Then press Build. Xcode will ask you to trust the SwiftTerm package plugin. The `Turm` scheme builds the Mac app and `TurmiOS` the iPhone and iPad app.

## Documentation

Project actions, the `Turm.json` project file, SSH, Remote Access, iCloud sync and the iOS app are documented in [docs](docs/README.md).

Bug reports and pull requests are welcome, see [CONTRIBUTING.md](CONTRIBUTING.md). Please report security problems privately as described in [SECURITY.md](SECURITY.md).

## License

Turm is released under the [MIT License](LICENSE).

---

<div align="center">

<a href="https://www.buymeacoffee.com/seggy116"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-violet.png" alt="Buy me a coffee" height="50" /></a>

</div>
