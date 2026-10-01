# iCloud sync

Turm can keep your SSH hosts, shortcuts and saved secrets the same on your Mac and your iPhone or iPad. Sync is off until you turn it on, on each device.

## What syncs

- SSH hosts, the same list as Settings > SSH.
- Global shortcuts. Project shortcuts stay with their project and do not sync.
- SSH passwords you chose to remember, and the sudo passwords Turm remembers for a host.
- SSH keys stored in Turm.

These do not sync:

- Project shortcuts.
- Interface preferences and usage statistics.
- Remote Access pairings. Each pairing stays on the device that made it. See [Remote Access](remote-access.md).
- On the iPhone, trusted host keys and the keyboard bar layout.

## How it travels

Everything goes through iCloud Keychain, which is end-to-end encrypted. Both devices must be signed in to the same Apple Account with Keychain turned on. If it is not available, the setting says so and sync stays off.

Turm reads from iCloud Keychain when it launches, when you switch back to it, about once a minute while it is in front, and when you press **Sync Now**. Changes you make are written straight away. If two devices edit the same item, the later edit wins. A deleted host, shortcut or key is deleted on your other devices too.

## Turning it on and off

On the Mac: Settings > iCloud, then **Sync with iCloud**. On the iPhone or iPad: Settings > iCloud Sync. Turning it on moves the passwords and keys already on that device into iCloud Keychain and merges the hosts and shortcuts with what is already there.

Turning it off only stops that device. It keeps its own copies of your hosts, shortcuts, passwords and keys, and the other devices carry on.

## Delete iCloud Data

**Delete iCloud Data** removes everything Turm has put in iCloud: hosts, shortcuts, passwords and keys. It turns sync off on the device you use it on. Your other devices turn sync off the next time they check, with a note that iCloud data was deleted from another device, and their synced passwords and keys are removed. Every device keeps its own hosts and shortcuts. The device you use it on also keeps local copies of its hosts, shortcuts, passwords and keys.

## Keys stored in Turm

A key file on your Mac is not available on your iPhone until you store it in Turm. Settings > iCloud has an **SSH Keys** group that lists the private keys in `~/.ssh` and any key file your hosts name. Each row shows the key type, fingerprint, the hosts that use it and whether it is stored in Turm. Switch a key on to copy it into Turm's keychain. If it is encrypted, Turm asks for its passphrase and keeps that in the keychain too. The file on your Mac is read once and is never changed or deleted. Switch the key off to remove it from Turm and from your other devices.

When you turn iCloud sync on and your hosts use keys that are not stored yet, Turm asks **Also sync the keys your hosts use?** and lists them, all ticked. Nothing is stored unless you confirm. The keys then travel through iCloud Keychain, which is end-to-end encrypted, and appear on your iPhone and iPad.

Storing a key also points every host whose key file is that file at the stored key, so the host syncs with the link. In a host you can pick **Default keys**, a key file on the Mac, or a key that is only stored in Turm, and **Store Key in Turm...** does the same for the key the host uses.

On the iPhone, a host that names a stored key signs in with it. A host that does not name one tries every stored key in the order OpenSSH uses (ed25519, then ECDSA, then RSA) and then asks for a password. Encrypted keys are used when their passphrase was stored with them; otherwise they are skipped.

Turm accepts OpenSSH private keys and RSA PEM keys of up to 64 KB. A public key is refused.

On the iPhone you can also import a key from Files or paste one, in Settings > SSH Keys.

## Synced hosts are checked

A host that arrives from iCloud is checked before it is used, because its fields end up in an `ssh` command. Turm skips a host if its host is empty, if the host or user has spaces or control characters or starts with a dash, if the user contains `@`, if the port is outside 1 to 65535, or if the key path starts with a dash or has control characters. If a synced host's name is already taken by another host, Turm adds a number to it, for example `prod2`.
