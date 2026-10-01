<div align="center">

<h1>
  <img src="https://raw.githubusercontent.com/Seggys116/Turm/main/.github/assets/icon.png" alt="" width="72" align="absmiddle" />
  &nbsp;Turm
</h1>

**A smart terminal for macOS.**

</div>

---

## Building

Requires macOS, Xcode and Node.js.

```
git clone https://github.com/Seggys116/Turm.git
cd Turm
npm ci --prefix Icons
open Turm.xcodeproj
```

The build fails until `npm ci --prefix Icons` has been run. It installs the pinned [Simple Icons](https://simpleicons.org) and [Lobe Icons](https://github.com/lobehub/lobe-icons) packages that the sidebar and project bar use for program and ecosystem logos, and generates `Icons/inputs.xcfilelist`, which lists the files the build phase may read. `Icons/manifest.json` lists the glyphs that are copied into the app at build time, and the build refuses any icon whose licence does not allow redistribution. Run `npm ci --prefix Icons` again after editing `Icons/manifest.json`.

Then press Build. Xcode will ask you to trust the SwiftTerm package plugin.

## Documentation

Project actions, the `Turm.json` project file, SSH, Remote Access, iCloud sync and the iOS app are documented in [docs](docs/README.md).

## License

Turm is released under the [MIT License](LICENSE).

---

<div align="center">

<a href="https://www.buymeacoffee.com/seggy116"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-violet.png" alt="Buy me a coffee" height="50" /></a>

</div>
