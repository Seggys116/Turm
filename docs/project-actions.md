# Project actions

The project bar at the bottom of a terminal pane offers one-click commands for the project in the shell's working directory: build, run, test, clean and so on. Turm works out the commands by looking at the files in your project. You can adjust the result app-wide in Settings and per project in a [`Turm.json`](turm-json.md).

The bar only appears when Turm found a project or a `Turm.json` for the current directory.

## How a project is detected

Turm starts in the shell's current directory and looks at that directory, then its parents. For each folder it checks, in this order:

1. Folders with no entries are skipped.
2. If any detector recognises the folder, detection stops there. Every detector that matches that one folder contributes, so a folder with both `Cargo.toml` and `package.json` gives you a Cargo group and a Node group.
3. Otherwise Turm moves to the parent.

The search covers at most 10 folders (the current one plus up to 9 parents). It never reaches your home folder or `/`. If the shell is itself in your home folder or `/`, only that folder is checked.

The nearest recognised folder wins, so in `~/code/app/src/` the actions come from `~/code/app/` if `src/` has no recognised files.

Each detected action runs in the folder where it was detected. When that differs from the shell's directory, Turm types `cd '<folder>' && <command>` for you.

### Detected ecosystems

An ecosystem is one detector's result and is the unit shown as a group in the bar. Action ids are the ecosystem id plus a dot plus the name listed below, for example `cargo.build`. You use these ids in `Turm.json` (`hide`, `bar.pinned`, `bar.icons`, overriding an action).

| Ecosystem id | Detects | Notable action ids |
|---|---|---|
| `cargo` | `Cargo.toml` (workspaces get `--workspace`) | `cargo.build`, `cargo.run` (needs `src/main.rs`, `src/bin` or a `[[bin]]`), `cargo.test`, `cargo.clean`, `cargo.check`, `cargo.clippy`, `cargo.fmt`, `cargo.bench` (needs `benches/`), `cargo.doc`, `cargo.update`, `cargo.tree` |
| `swiftpm` | `Package.swift` | `swiftpm.build`, `swiftpm.run` (executable target), `swiftpm.test`, `swiftpm.clean`, `swiftpm.resolve`, `swiftpm.update`, `swiftpm.describe` |
| `xcode` | first `.xcworkspace`, else first `.xcodeproj`; the scheme is taken from its file name | `xcode.build`, `xcode.test`, `xcode.clean`, `xcode.archive`, `xcode.list`, `xcode.open` |
| `node` | `package.json`; package manager from its `packageManager` field, else the lockfile (pnpm, bun, yarn), else npm. A known framework (Next.js, Nuxt, Astro, SvelteKit, Remix, Angular, Vite, Create React App, Expo, Electron) is named in the title | `node.install`, `node.s.<script>` for each package script (for example `node.s.dev`, `node.s.build`, `node.s.test`; the first 40 alphabetically), `node.fw.dev` and `node.fw.build` when a framework is present but no matching script, `node.tsc`, `node.update`, `node.outdated`, `node.list` |
| `tauri` | a Tauri config in `src-tauri/` or the root | `tauri.dev`, `tauri.build`, `tauri.info`, `tauri.check`, `tauri.clippy` |
| `deno` | `deno.json` or `deno.jsonc` (tasks are read from `deno.json` only) | `deno.t.<task>`, `deno.test`, `deno.check`, `deno.lint`, `deno.fmt` |
| `python` | `pyproject.toml`, `requirements.txt`, `setup.py`, `setup.cfg`, `Pipfile`, `manage.py`, `uv.lock` or `poetry.lock`; uv, poetry, pipenv or plain pip; Django when `manage.py` exists | `python.install`, `python.run`, `python.django.run`, `python.django.migrate`, `python.django.makemigrations`, `python.django.shell`, `python.test`, `python.test.fast`, `python.ruff.check`, `python.ruff.fix`, `python.ruff.format`, `python.black`, `python.mypy`, `python.build`, `python.update`, `python.venv`, `python.outdated` |
| `go` | `go.mod` | `go.build`, `go.run` (needs `main.go`), `go.test`, `go.clean`, `go.vet`, `go.fmt`, `go.cover`, `go.bench`, `go.tidy`, `go.get` |
| `cmake` | `CMakeLists.txt` | `cmake.build`, `cmake.test`, `cmake.clean`, `cmake.configure`, `cmake.install`, `cmake.presets` (needs `CMakePresets.json`) |
| `meson` | `meson.build` | `meson.build`, `meson.test`, `meson.clean`, `meson.reconfigure` |
| `make` | `GNUmakefile`, `Makefile` or `makefile` | `make.default`, `make.t.<target>` for each target (the first 40), `make.dry` |
| `gradle` | `build.gradle(.kts)` or `settings.gradle(.kts)`; uses `./gradlew` when present | `gradle.build`, `gradle.run` (application plugin), `gradle.test`, `gradle.clean`, `gradle.assemble`, `gradle.check`, `gradle.tasks`, `gradle.deps` |
| `maven` | `pom.xml`; uses `./mvnw` when present | `maven.package`, `maven.run` (Spring Boot plugin), `maven.test`, `maven.clean`, `maven.compile`, `maven.verify`, `maven.install`, `maven.tree` |
| `dotnet` | `.csproj`, `.fsproj`, `.vbproj`, `.sln` or `.slnx` | `dotnet.build`, `dotnet.run` and `dotnet.watch` (project files only), `dotnet.test`, `dotnet.clean`, `dotnet.restore`, `dotnet.format`, `dotnet.publish` |
| `zig` | `build.zig` | `zig.build`, `zig.run`, `zig.test`, `zig.fmt` |
| `mix` | `mix.exs` (Phoenix when it mentions `:phoenix`) | `mix.compile`, `mix.server` (Phoenix) or `mix.run`, `mix.test`, `mix.clean`, `mix.iex`, `mix.format`, `mix.deps` |
| `dart` | `pubspec.yaml`; Flutter when it contains `flutter:` | `dart.build` (Flutter), `dart.run`, `dart.test`, `dart.clean` (Flutter), `dart.analyze`, `dart.format`, `dart.get`, `dart.upgrade` |
| `ruby` | `Gemfile`; Rails when `config/application.rb` or `bin/rails` exists | `ruby.install`, `ruby.server`, `ruby.console`, `ruby.migrate`, `ruby.routes` (Rails), `ruby.test`, `ruby.rake`, `ruby.rubocop`, `ruby.rubocop.fix`, `ruby.update`, `ruby.outdated` |
| `php` | `composer.json`; Laravel when `artisan` exists | `php.install`, `php.serve`, `php.test`, `php.migrate` (Laravel), `php.s.<script>` for Composer scripts, `php.update`, `php.outdated` |
| `nix` | `flake.nix` | `nix.build`, `nix.run`, `nix.check`, `nix.develop`, `nix.update` |
| `just` | `justfile`, `Justfile` or `.justfile` | `just.r.<recipe>` |
| `task` | `Taskfile.yml`/`.yaml` (either case) | `task.r.<task>` |
| `docker` | a Compose file and/or `Dockerfile` | `docker.up`, `docker.up.detached`, `docker.build`, `docker.down`, `docker.logs`, `docker.ps`, `docker.pull`, `docker.restart`, `docker.image`, `docker.image.run` |
| `terraform` | any `*.tf` file | `terraform.init`, `terraform.validate`, `terraform.plan`, `terraform.apply`, `terraform.fmt`, `terraform.output`, `terraform.state` |

A group with the id `project` (titled "Project") is added first when your `Turm.json` defines custom actions or variants. Custom actions get whatever id you give them (see [Turm.json](turm-json.md)).

Every action has a category: Run, Build, Test, Check, Clean, Dependencies or Other. The category sets the default icon and how actions are grouped. Actions marked as featured are the ones placed on the bar by default (see below).

## Option toggles (variants)

Some commands have a switch that changes them, such as Debug or Release. These are called variants. A variant has a set of options; the selected option's value is substituted into the command wherever `{variant-id}` appears.

| Variant id | Ecosystem | Options (label: substituted value) |
|---|---|---|
| `cargo-profile` | `cargo` | Debug: nothing, Release: `--release` |
| `swift-configuration` | `swiftpm` | Debug: `-c debug`, Release: `-c release` |
| `xcode-configuration` | `xcode` | Debug: `Debug`, Release: `Release` |
| `cmake-config` | `cmake` | Debug, Release, RelWithDebInfo, MinSizeRel |
| `meson-buildtype` | `meson` | Debug: `--buildtype=debug`, Release: `--buildtype=release` |
| `go-race` | `go` | Race off: nothing, Race on: `-race` |
| `dotnet-config` | `dotnet` | Debug: `-c Debug`, Release: `-c Release` |
| `zig-optimize` | `zig` | Debug: nothing, ReleaseSafe, ReleaseFast, ReleaseSmall (each `-Doptimize=...`) |
| `tauri-bundle` | `tauri` | Release: nothing (the default), Debug: `--debug` |

When an option's value is empty, the extra space is removed from the command. Your choice is remembered per project folder and per variant. You can add your own variants in `Turm.json`, and use the detected ones in your own commands, for example `cargo run {cargo-profile} -- --verbose`.

## The bar

The bar is always at the bottom of the pane. From left to right it holds:

- **Tool selector:** a dropdown chip fixed to the left edge, for example "Cargo". It appears only when more than one tool is detected and the project has no `Turm.json`. Choosing a tool switches which tool's pinned actions and option toggles are shown. With a single detected tool, or with a `Turm.json`, there is no selector.
- **Pinned actions and option toggles:** one-click action buttons, and small dropdown chips for option toggles (Release/Debug and so on). An option chip shows the current option; clicking it lists the options and choosing one selects it. Actions come first and option toggles second unless `bar.order` in `Turm.json` says otherwise (Settings has no control for this). Then `bar.alignment` or the Settings alignment places the items along the bar. Anything that does not fit on the bar collapses into the "..." menu.
- **"..." menu:** opens a menu with everything the project offers: option toggles first (each row shows the current option, and clicking it switches to the next), then all actions grouped by category, or grouped by ecosystem (and by category within each) when there are several groups. Its last row is "Edit Turm.json" when the project has one, or "Create Turm.json", which writes a starter file next to the first detected project.
- **Run state:** Stop, Watch and similar controls appear while an action runs (see [Running in a sub-shell](#running-in-a-sub-shell)).

Actions defined in `Turm.json` (the group with id `project`) are always visible. They are not an entry in the tool selector.

What the bar shows depends on whether the project has a `Turm.json`:

- **No `Turm.json`, several tools detected:** the selector and the chosen tool's items.
- **No `Turm.json`, one tool:** that tool's items.
- **With a `Turm.json`, no selector:** every enabled ecosystem's items, or exactly the actions in `bar.pinned`, in that order, when it is set. Option toggles still come from each ecosystem's items.

Each ecosystem's items are its featured actions plus all its option toggles, unless you changed them in Settings.

The bar is hidden when "Show project bar" is off in Settings, or when nothing was detected and there is no `Turm.json` warning to report. If `Turm.json` could not be read, the bar shows a warning with the reason (and the "..." menu repeats it). See [Broken files](turm-json.md#broken-files). A file that could not be read still counts as a `Turm.json` for the selector rule above.

Actions are disabled while the pane's shell is busy. In sub-shell mode they are disabled while a sub-shell action is running.

## Settings: Project Bar tab

The Project Bar tab in Settings sets the app-wide defaults. A note at the bottom reminds you that a `Turm.json` in a project overrides these settings for that project.

**Project Bar section**

- Show project bar: turns the bar off everywhere.
- Alignment: Left, Centre or Right.
- Labels: Auto, Always or Never. Auto hides action labels (leaving icons) when the bar is too narrow.
- Run actions in a sub-shell: on by default. See [Running in a sub-shell](#running-in-a-sub-shell).

**Ecosystems section**

A grid of pills, one per ecosystem Turm can detect, whether or not one is open in a shell. Selecting a pill shows that ecosystem's section:

- Enabled: when off, the ecosystem is left out of the bar and the "..." menu.
- An editor with two areas, drawn as bar-styled strips. It uses the same buttons and chips as the real bar. "On the bar" holds the action and option chips shown on the bar, in order. "Available" holds the rest.
  - Drag a chip to reorder it, or drop it on the bar to add it.
  - Click an Available chip to add it at the end.
  - Click the X that appears when you hover a chip, or drag it off the bar into Available, to remove it.
  - Anything that does not fit on the bar collapses into the "..." menu.
- Reset to defaults: clears that ecosystem's settings. It is disabled when there is nothing to reset.

The editor's default content is the ecosystem's featured actions followed by its option toggles.

## Choosing what is on the bar

Items on the bar come from, in order of precedence:

1. `bar.pinned` in the project's `Turm.json`: exactly those action ids, in that order, across all ecosystems. Option toggles are still taken from the ecosystem items below.
2. Otherwise, each ecosystem's items: what you arranged in Settings, or the featured actions plus option toggles until you change it.

## Running in a sub-shell

Sub-shell mode is on by default. Turm starts a hidden shell in the action's folder and runs the command there, so the pane's own shell is not used and stays free. With sub-shell mode off, the command is typed into the pane's own shell instead.

- While the command runs, the bar fills only when the program itself reports progress through the terminal's progress sequence (OSC 9;4). A determinate value fills the bar green in proportion, an indeterminate report shows a moving segment, an error report is red, and a paused report is grey. A program that reports nothing shows no fill, only a small spinner next to the command. Turm does not estimate progress.
- On success the bar gives a brief green wash that fades.
- On failure (a non-zero exit code, or the hidden shell closing early) the bar pulses red and the exit code is shown. After 8 seconds the pulse settles to a steady red glow, which stays until you dismiss the result or start another action.
- A Watch button (Interact when a full-screen program is running) opens the hidden shell's output as an overlay on the pane. The overlay is a full terminal, so you can select text and use interactive programs. Its header has Stop (while running), "Pop out into its own shell", hide, and close-and-discard buttons. Pop out hands the hidden shell to the workspace as a new tab and keeps its process running. The bar then clears its run state, so it stops showing progress for that action.
- Stop on the bar interrupts the running command (Ctrl-C). The hidden shell stays open afterwards until you dismiss it with the x button on the bar, pop it out, or start another action.
- Starting another action replaces the previous finished sub-shell automatically. While an action is still running, other actions are disabled, so stop it first.

Turn it off in Settings under Run actions in a sub-shell, or set it per project with `bar.subShell` in `Turm.json`, which overrides the app-wide setting.

## App-wide settings and Turm.json

App-wide settings apply to every project. `Turm.json` applies only to the project it belongs to and wins whenever both set the same thing.

| Setting | App-wide default | Turm.json field | Notes |
|---|---|---|---|
| Bar shown | on | none | Off hides the bar in every project, regardless of `Turm.json`. |
| Alignment | left | `bar.alignment` | `leading`, `center` or `trailing`. |
| Titles | auto | `bar.titles` | `auto`, `always` or `never`. |
| Layout order | actions, options (no Settings control) | `bar.order` | Entries are `actions` (pinned actions) and `options` (option toggles). Repeats and unknown entries are dropped and missing sections are added at the end. |
| Items on the bar | per ecosystem | `bar.pinned` | The project list of action ids replaces the per-ecosystem action lists. |
| Run in sub-shell | on | `bar.subShell` | |
| Ecosystem on or off | on | `bar.ecosystems.<id>.hidden` | The ecosystem is hidden if either the app-wide setting or the project hides it. |

Settings only in `Turm.json`: `inherit`, `hide`, `variants`, `actions`, `bar.icons`, and each ecosystem's `title` and `icon`.

App-wide settings are stored in Turm's preferences (key `turm.statusBar`), not in a file you edit by hand. Per ecosystem they hold `enabled` and `items`, the ordered ids of the actions and option toggles on the bar.
