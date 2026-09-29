# Shortcuts

Shortcuts are short keys you type in the input instead of long paths or commands. The first character says what kind a shortcut is:

| Sigil | Kind | Becomes |
|---|---|---|
| `@` | Directory | a folder path, or a change of folder at the start of a line |
| `!` | Command | a saved command |
| `#` | File | a file path |

Keys may use letters, digits, `-`, `_` and `.`. Case doesn't matter when matching. Each key is unique within its kind, so `@api` and `#api` can both exist.

## Adding shortcuts

Besides Settings, you can create shortcuts from what you are already doing:

- Right-click a command block and choose **Save as Command Shortcut...**.
- Right-click a path in the input, including a file you dropped in, and choose **Save as File Shortcut...** or **Save as Directory Shortcut...**. Right-clicking a shortcut in the input offers **Edit** for it.
- Turm notices folders you keep returning to (5 visits) and long commands you keep running (4 runs, 20 characters or more). It then shows a hint above the input with a one-click **Save as** button. Close the hint with its x to stop it coming back for that folder or command.

- **Directories:** click the folder chip above the input and choose **Add Shortcut...**, or use **Choose Folder...** in Settings > Shortcuts. New directory shortcuts start with the folder name as their display name.
- **Commands:** Settings > Shortcuts > **Add Command...**.
- **Files:** Settings > Shortcuts > **Choose File...**.

In Settings, **Edit** changes the key and name, **Change...** points a directory or file shortcut at a different location, and **Remove** deletes it. For the current folder, the folder chip also offers **Edit Shortcut** and **Remove Shortcut**.

## Using shortcuts

A shortcut counts when it starts a word outside quotes, including straight after `=`, `;`, `|`, `&`, `(` or `<`/`>`. It is expanded when you press Return.

| You type | Turm runs |
|---|---|
| `@api` | `cd '<api folder>'` |
| `@api/src/routes` | `cd '<api folder>/src/routes'` |
| `@api npm test` | `cd '<api folder>' && npm test` |
| `cp #cfg @web/public` | `cp '<cfg file>' '<web folder>/public'` |
| `!build --watch` | `<build command> --watch` |
| `tool --config=#cfg` | `tool --config='<cfg file>'` |

Only a directory shortcut at the very start of the line changes folder. Anywhere else it becomes the quoted path. Paths are quoted for your shell (zsh, bash or fish). The command block shows what actually ran, and history keeps what you typed. A word that looks like a shortcut but has no matching key is sent to the shell unchanged.

## Command arguments

A command shortcut can take the words typed after it. `{1}`, `{2}` and so on insert the first, second and later words. `{@}` inserts all of them. Words stop at the first `;`, `|`, `&` or other operator, keep any quotes you typed, and may be shortcuts themselves.

| Shortcut | You type | Turm runs |
|---|---|---|
| `!gco` = `git checkout {1}` | `!gco feature --force` | `git checkout feature --force` |
| `!edit` = `code {1}` | `!edit #cfg` | `code '<cfg file>'` |
| `!note` = `echo {@} >> notes.txt` | `!note ship it` | `echo ship it >> notes.txt` |

Words a placeholder doesn't use stay after the command. A shortcut without placeholders leaves every word where it is.

## Project shortcuts

A project's `Turm.json` can define shortcuts that only apply inside that project. A project shortcut overrides a global shortcut with the same kind and key. Relative paths are resolved from the project folder. Their tags are marked `project`. See [Turm.json shortcuts](turm-json.md#shortcuts).

## While typing

- A tag above each recognised shortcut shows the path or the finished command it stands for. Click the tag to select that shortcut, and its arguments, in the input. Option-click it to replace the shortcut with that text so you can edit it before running.
- If a directory or file shortcut points at something that no longer exists, its tag turns red and says `missing`, the shortcut is underlined as an error, and Settings shows a **Missing** badge next to it. Use **Change...** to point it somewhere else.
- Typing `@`, `#` or `!` lists the matching shortcuts. After `@api/`, the folders inside it are listed.
- Recognised shortcuts are coloured like aliases. After a leading directory shortcut, file completion works from inside that folder.

## Spotlight

The slim search field in the middle of the title bar is the spotlight. Click it or press Cmd+T and it opens into a panel in the same place. Plain **New Shell** is Option-Cmd+T.

- The field is coloured like the input as you type: commands, flags, strings and shortcuts, with missing shortcut paths in red.
- With nothing typed, the list offers a new shell in the current folder, your directory and command shortcuts, and recent commands. Enter on an empty field opens a new shell in the current folder.
- Type a command and press Enter to run it in a new shell tab in the current folder. Start it with a directory shortcut, as in `@api npm test`, to run it in that folder instead. `@api` alone opens a shell there.
- Typing matches shortcut keys, names and values, and your history. `@` or `!` at the start narrows the list to that kind.
- `#file` and `!command` shortcuts and arguments in the typed line expand exactly as they do in the input.
- Up and Down move through the list. Tab puts the selected shortcut or history entry into the field so you can keep typing. Esc, or clicking anywhere else, closes it.

### Searching with `?`

Start with `?` to search what is open instead of running something:

- `?` alone lists every shell, one row per pane, with its folder, git branch and any running command, plus Settings if it's open.
- `?api` finds shells whose title, folder, branch or past commands match. Several words must all match.
- Below the shells, matching commands from each shell's history are listed as `npm test  in api`.
- Enter on a shell switches to it. Enter on a command switches to that shell and opens Find with the command filled in, so its block is highlighted.

## Where directory names appear

When the shell is in a folder that has a directory shortcut, the folder chip, the sidebar title and each command block's header show its display name. If the display name is empty, they show the key. Below that folder the rest of the path is appended, for example `Backend/src`. If shortcuts are nested, the deepest one wins. Hovering the folder chip shows the full path, and sidebar search matches both.
