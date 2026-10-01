# SSH

Turm keeps its block view over SSH. Every remote command gets its own block, with its exit code and the remote folder. Local-only features are switched off while you are connected.

## Connecting with `>`

Type `>` followed by a host at the start of the line and press Return.

| You type | Turm runs |
|---|---|
| `>prod` | `ssh` with the saved host's user, port and key |
| `>prod uptime` | the same, running `uptime` on the host |
| `>bob@example.com:2222` | `ssh -p 2222 bob@example.com` |
| `>build-box` | `ssh build-box`, for a `Host` in `~/.ssh/config` |

While you type, the completion list shows saved hosts first, then the hosts from your SSH config and known hosts. `>` only means SSH at the start of the line and directly followed by a name. `> file` with a space is still an ordinary redirect.

## Saved hosts

Settings > SSH lists your hosts. **Add Host...** takes:

- **Name:** the key after `>`.
- **Host:** a hostname, an address or a `Host` alias from your SSH config.
- **User and Port:** both optional.
- **Key:** Automatic lets ssh choose. You can also pick one of the keys Turm found in `~/.ssh` (files with a private key header, shown with their type and comment), or **Choose File...**. **Detect** asks the server which of your keys it accepts and selects that one. A key the server accepts but that needs its passphrase is marked as such. A new host saved with Automatic is detected once in the background.
- **Password:** optional. With **Remember in Keychain** on, it is stored in the Keychain: on this Mac only, or in iCloud Keychain for your other devices when [iCloud sync](icloud-sync.md) is on. With it off, Turm holds it in memory until it quits. Turm only types it at the prompt that names this host's own `user@host`, and only once per connection, so a jump host never receives it. A key is still the better choice.

**Import from SSH config** turns `Host` entries into saved hosts.

## Remote shell integration

The first time you connect to a server without Turm's hooks, a bar above the input offers to install them:

- **Install** copies Turm's zsh, bash and fish hooks into `~/.turm/shell` on the server. It never edits the server's `.zshrc`, `.bashrc` or other startup files, so sessions from other terminals are unaffected. **Use in this session** switches the open connection over. Later connections use the hooks automatically.
- **Not now** asks again next time. **Never for this host** stops asking. You can undo that in Settings > SSH.

Turm does this over the connection you already opened, through a private ssh control socket, so there is no second login or password prompt. When a newer Turm changes its hooks, the next connection to a host with older ones offers **Update** instead of replacing them silently.

The server must use zsh, bash or fish as its login shell. Bash older than 4.4 has no bracketed paste, so Turm types commands into it line by line. Settings > SSH lists the hosts with the integration installed:

- **Uninstall** removes `~/.turm/shell` from the server. This needs key login.
- **Forget** stops Turm launching through the hooks but leaves the files on the server.

The `ssh` wrapper is only added when you have not defined your own `ssh` function or alias. If you have, connections still work but stay a plain terminal.

## While connected

Over a connection made through Turm's `ssh`, Turm runs short helper commands on the server through the same control socket. Nothing is installed for this beyond the prompt hooks.

- **Chips:** the host chip shows the saved name, or `user@host`. Click it to save the server as an SSH host or a command shortcut, copy its address or ssh command, or disconnect. The folder chip next to it copies the remote path, including a `user@host:path` form for scp.
- **Tab completion:** remote folders and files, the commands on the server's `PATH`, its environment variables, git branches and tags, and its processes. Unknown commands are highlighted in red, as they are locally.
- **Git chip:** shows the server repository's branch and changes, and the branch menu switches branches on the server.
- **Project bar:** detects the server's project (package.json, Cargo.toml, Makefile, compose files, Turm.json and the rest) exactly as it does locally. Actions run in the remote shell. Sub-shell mode is local only.
- **Pasting or dropping a file or image:** uploads it to a private `turm-<uid>` folder in the server's temp directory and inserts that path.
- **Other programs:** progress bars and full-screen programs such as `vim` or `htop` work as they do locally.
- **Shortcuts:** command shortcuts (`!`) still expand. Directory and file shortcuts do not, since they point at local paths.

After a second ssh hop from the server, or when you use your own `ssh` function, Turm has no control socket. Blocks and exit codes still work there, but completion, git and the project bar are off.

When the connection ends, Turm returns to the local shell. If it dropped while idle, a "Disconnected" block shows ssh's last message. If the server's hooks are older than your Turm, the bar above the input offers **Update**, then **Reload shell** to use them straight away.
