# Turm.json reference

`Turm.json` is an optional file that adjusts the [project actions](project-actions.md) bar for one project. Every field is optional.

## Where Turm looks for it

Turm checks the shell's current directory, then its parents (at most 10 folders, never your home folder or `/`; if the shell is in one of those, only that folder is checked). The first `Turm.json` found is the only one used. Files are not merged.

The name is matched without regard to case, so `turm.json` and `TURM.json` work too. If a folder on a case-sensitive volume holds several spellings, `Turm.json` wins, otherwise the first in sorted order.

This search is separate from project detection, so `Turm.json` can sit in a parent folder above the project. Actions defined in `Turm.json` run from the folder that holds the file (Turm adds `cd` when the shell is somewhere else). See [Monorepo](#monorepo).

## Minimal Turm.json

One custom action, everything detected is kept:

```json
{
  "actions": [
    { "title": "Deploy", "command": "./scripts/deploy.sh" }
  ]
}
```

## Full example

```json
{
  "inherit": true,
  "hide": ["cargo.doc", "cargo.tree", "node.outdated"],
  "variants": [
    {
      "id": "target",
      "title": "Target",
      "options": [
        { "label": "Debug", "value": "debug" },
        { "label": "Release", "value": "release" }
      ],
      "defaultOption": 0
    },
    { "id": "region", "options": ["eu", "us"] }
  ],
  "actions": [
    {
      "id": "deploy",
      "title": "Deploy",
      "command": "./scripts/deploy.sh --target {target} --region {region}",
      "icon": "paperplane",
      "category": "run",
      "featured": true,
      "env": { "DEPLOY_ENV": "staging" }
    },
    { "id": "cargo.test", "title": "Test (nextest)", "command": "cargo nextest run {cargo-profile}" }
  ],
  "bar": {
    "pinned": ["cargo.build", "cargo.test", "deploy"],
    "icons": { "cargo.build": "hammer.fill", "deploy": "paperplane.fill" },
    "ecosystems": {
      "cargo": { "title": "Rust", "icon": "gearshape.2" },
      "docker": { "hidden": true }
    },
    "titles": "auto",
    "alignment": "leading",
    "subShell": true
  }
}
```

## Top-level fields

| Field | Type | Meaning |
|---|---|---|
| `inherit` | boolean | `false` turns off detection entirely, so only what this file defines is shown. Anything else (or absent) keeps detected actions. |
| `hide` | array of strings | Action ids to remove from the detected actions, for example `"cargo.doc"`. Ids are listed in [Detected ecosystems](project-actions.md#detected-ecosystems). Removes actions only, not option toggles. Custom actions defined in the same file are not affected. |
| `variants` | array | Option toggles, see [Variants](#variants). |
| `actions` | array | Custom or overriding actions, see [Actions](#actions). |
| `bar` | object | Layout and pinning for this project, see [The bar block](#the-bar-block). |
| `shortcuts` | object of strings | Shortcuts that only apply inside this project, see [Shortcuts](#shortcuts). |

Unknown fields are ignored.

## Actions

Each entry in `actions`:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `title` | string | yes | Label shown for the action. Surrounding spaces are trimmed. |
| `command` | string | yes | The command line. `{variant-id}` placeholders are replaced with the selected option's value. |
| `id` | string | no | Identifier for pinning, hiding and icons. Defaults to `turm.<position>`, where position is the entry's index in `actions` (starting at 0). |
| `icon` | string | no | An SF Symbol name such as `paperplane`. Defaults to the category's icon. |
| `category` | string | no | One of `run`, `build`, `test`, `check`, `clean`, `deps`, `other` (case-insensitive). Anything else, or absent, is `other`. |
| `featured` | boolean | no | Whether the action is on the bar by default. Defaults to `true` for a new action. |
| `env` | object of strings | no | Environment variables for this command. Variables are set only for the first command of a compound line, and names must be valid identifiers (letters, digits and underscores, not starting with a digit); others are ignored. |

Entries whose `title` or `command` is empty after trimming are skipped silently.

New actions are listed first, in a group called "Project" (ecosystem id `project`).

### Overriding a detected action

Give a custom action the id of a detected one. It replaces the detected action, stays in the detected action's ecosystem, and keeps its `featured` value unless you set one. Like every action from this file, it runs from the folder that holds `Turm.json`, which matters if that is a parent of the project.

```json
{
  "actions": [
    { "id": "cargo.test", "title": "Test", "command": "cargo nextest run {cargo-profile}" },
    { "id": "node.s.dev", "title": "Dev server", "command": "pnpm run dev --host", "icon": "bolt.fill" }
  ]
}
```

### Hiding detected actions

```json
{
  "hide": ["cargo.doc", "cargo.update", "cargo.tree", "node.update", "node.outdated", "node.list"]
}
```

To drop everything detected and keep only your own actions:

```json
{
  "inherit": false,
  "actions": [
    { "id": "up", "title": "Start stack", "command": "docker compose up -d", "category": "run" },
    { "id": "down", "title": "Stop stack", "command": "docker compose down", "category": "other" }
  ]
}
```

### How a command is built

When you run an action, Turm builds the text to run in this order:

1. Each `{variant-id}` is replaced by the selected option's value. This covers detected variants too (`{cargo-profile}`, `{swift-configuration}`, and so on; see the [variant table](project-actions.md#option-toggles-variants)). Repeated spaces outside quotes are collapsed, so an empty value leaves no gap.
2. If `env` is set, the command is prefixed with `env KEY='value' ...`. Keys are sorted, values are single-quoted.
3. If the action's folder differs from the shell's directory, `cd '<folder>' && ` is put in front. In sub-shell mode the hidden shell starts in the action's folder, so no `cd` is added.

For the `deploy` action in the full example above, with Release and `eu` selected and the shell in the same folder, Turm runs:

```
env DEPLOY_ENV='staging' ./scripts/deploy.sh --target release --region eu
```

Placeholders are matched by exact text `{id}`. A placeholder with no matching variant is left in the command unchanged.

## Variants

A variant is an option toggle shown on the bar. Each entry in `variants`:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | string | yes | Used as `{id}` in commands. Must not be empty. |
| `title` | string | no | Name shown for the toggle. Defaults to `id`. |
| `options` | array | yes | At least one option. An option is a string (used as both label and value) or an object `{ "label": ..., "value": ... }`. If `value` is missing it equals `label`. Options with an empty label are dropped. |
| `defaultOption` | integer | no | Zero-based index of the initial option. Values out of range are clamped. Defaults to 0. |

A variant with no `id` or no usable options is skipped. A variant with the id of a detected one (for example `cargo-profile`) replaces it and moves to the "Project" group.

```json
{
  "variants": [
    {
      "id": "cargo-profile",
      "title": "Profile",
      "options": [
        { "label": "Dev", "value": "" },
        { "label": "Release", "value": "--release" },
        { "label": "Bench", "value": "--profile bench" }
      ],
      "defaultOption": 1
    },
    { "id": "features", "title": "Features", "options": [
        { "label": "Default", "value": "" },
        { "label": "All", "value": "--all-features" }
    ] }
  ],
  "actions": [
    { "id": "cargo.build", "title": "Build", "command": "cargo build {cargo-profile} {features}" }
  ]
}
```

The chosen option is remembered per project folder and per variant id.

## The bar block

Values here override the app-wide Project Bar settings for this project. The bar is always at the bottom of the pane, so there is no position field. Because a project with a `Turm.json` never shows the tool selector, the bar shows every ecosystem's items, or exactly `pinned` when it is set.

| Field | Type | Meaning |
|---|---|---|
| `pinned` | array of action ids | Actions shown as buttons, in this order. Ids not present (or from an ecosystem that is hidden or disabled) are ignored. Replaces the per-ecosystem action lists; the option dropdowns from each ecosystem's Settings follow the pinned actions. Actions that do not fit collapse into the "..." menu. |
| `icons` | object, action id to SF Symbol name | Icon per action. Wins over the action's own `icon`. |
| `ecosystems` | object, ecosystem id to settings | Per-ecosystem `title` (string), `icon` (SF Symbol name) and `hidden` (boolean). Use the ids from the [ecosystem table](project-actions.md#detected-ecosystems), or `project` for the custom group. |
| `titles` | string | `auto`, `always` or `never`. |
| `alignment` | string | `leading`, `center` or `trailing`. |
| `subShell` | boolean | Run actions in a hidden sub-shell. See [Running in a sub-shell](project-actions.md#running-in-a-sub-shell). |

String values are matched case-insensitively. An unrecognised value for `titles` or `alignment` is ignored and the app-wide setting is used.

### Icons

Icons are SF Symbol names, the same names shown in Apple's SF Symbols app. They can also be a brand logo written as `brand:<key>`, for example `brand:docker`. The keys are the left-hand names in `Icons/manifest.json`; an unknown key shows a generic terminal symbol.

```json
{
  "actions": [
    { "id": "lint", "title": "Lint", "command": "npm run lint", "icon": "checklist" }
  ],
  "bar": {
    "icons": {
      "node.s.dev": "bolt.fill",
      "node.s.build": "hammer.fill",
      "lint": "wand.and.stars"
    },
    "ecosystems": {
      "node": { "icon": "curlybraces" },
      "project": { "title": "Tools", "icon": "wrench.and.screwdriver" }
    }
  }
}
```

Default icons per category: run `play.fill`, build `hammer.fill`, test `checkmark.seal.fill`, check `checklist`, clean `trash`, deps `shippingbox`, other `terminal`. Detected actions may carry their own icon.

## Shortcuts

`shortcuts` maps a shortcut token to its value. The first character of the token sets the kind, as described in [Shortcuts](shortcuts.md):

```json
{
  "shortcuts": {
    "@web": "apps/web",
    "#env": ".env",
    "!dev": "pnpm dev",
    "!mig": "pnpm prisma migrate dev --name {1}"
  }
}
```

- Directory (`@`) and file (`#`) values are relative to the folder holding `Turm.json`. Values starting with `/` or `~` are used as they are.
- Command (`!`) values are used as written, including `{1}`, `{2}` and `{@}` argument placeholders.
- These shortcuts apply to shells anywhere inside the project and override a global shortcut with the same kind and key.
- An entry with no valid kind or key, or an empty value, is skipped and reported as `Turm.json: invalid shortcut <token>`.

## Monorepo

Put one `Turm.json` at the repository root. Open a shell in any package below it and Turm finds the file by walking up, while detection runs against the package itself.

```
repo/
  Turm.json
  services/
    api/         (Cargo.toml)
    web/         (package.json)
```

```json
{
  "actions": [
    { "id": "stack.up", "title": "Start stack", "command": "docker compose up -d", "icon": "play.circle", "category": "run" },
    { "id": "stack.down", "title": "Stop stack", "command": "docker compose down", "icon": "stop.circle" },
    { "id": "lint.all", "title": "Lint all", "command": "./scripts/lint-all.sh", "category": "check" }
  ],
  "bar": { "pinned": ["stack.up", "stack.down"] }
}
```

In `services/web`, Turm detects Node from `services/web/package.json` and adds a "Project" group with the three actions above. Those three run from `repo/`, where the file lives; detected actions run from `services/web`. With sub-shell mode off, Turm types `cd '/path/to/repo' && docker compose up -d` into the pane's shell for the custom ones.

Because only one `Turm.json` is used, a `Turm.json` inside `services/web` would be used there instead of the one at the root.

Because a `Turm.json` exists, there is no tool selector. `bar.pinned` above puts only the two stack actions on the bar, and the detected Node actions and "Lint all" are reachable from the "..." menu.

## Broken files

If `Turm.json` cannot be read or parsed, Turm shows a warning on the bar, ignores the file's contents (including `bar`), and still shows the detected actions.

```json
{
  "actions": [
    { "id": "deploy", "title": "Deploy" }
  ]
}
```

This file has no `command`, so the bar shows:

```
Turm.json: missing "command"
```

The reason text is one of:

| Message | Cause |
|---|---|
| `Turm.json: invalid JSON` | The file is not valid JSON, for example a trailing comma or a missing quote. |
| `Turm.json: missing "<field>"` | A required field is absent (`title` or `command` in an action, `id` or `options` in a variant, `label` in an option object). |
| `Turm.json: invalid value at <path>` | A field has the wrong type, for example `"subShell": "yes"` or `"actions": {}`. |
| `Turm.json: could not be read` | The file exists but Turm could not open or read it. |
| `Turm.json: invalid shortcut <tokens>` | A `shortcuts` entry has no `@`, `#` or `!` in front, a key with characters other than letters, digits, `-`, `_` and `.`, or an empty value. |

Fields that decode but hold unusable values (an empty title, an unknown `alignment`) are skipped without a warning.
