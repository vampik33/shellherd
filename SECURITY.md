# Security

## Reporting a vulnerability

Please report it privately through GitHub:
[Report a vulnerability](https://github.com/vampik33/shellherd/security/advisories/new)
(Security tab of this repository). Do not open a public issue for it.

Only the latest release gets fixes.

## What the app protects, and how

- **Private keys and passwords.** They are stored with
  flutter_secure_storage, which encrypts them with a key in the Android
  Keystore. An imported key keeps no passphrase: the Keystore protects it
  instead. The list of hosts (`hosts.json`) holds no secrets, and the app's
  data is left out of Android backups (`android:allowBackup="false"`).
- **Server keys.** The first connection to an address and port shows the
  server's key fingerprint and logs in only after you trust it. After that, a
  different key, also one of another type, stops the connection and shows
  both fingerprints. Only "Forget the server key" on the host's edit screen
  clears a trusted key.
- **Commands run on the computer.** Values from the host settings, such as a
  socket path or the mosh-server path, are shell-quoted before they reach a
  remote shell.
- **mosh.** The session key comes from mosh-server over the SSH connection;
  the app accepts only packets that mosh-server sent.
- **Text from panes.** The text view of a pane keeps only colour and style
  escape sequences. The terminal view is a full terminal emulator, as in any
  SSH client. While a program uses bracketed paste, pasted text loses its
  control characters, so it cannot end the paste early.
- **Notifications.** On the lock screen their text stays hidden unless the
  phone is set to show sensitive content there.
- **Tailscale check.** A link that Tailscale SSH sends in the login banner is
  shown in full and opens in the browser only when you tap it.

## Outside the threat model

- **The computers you connect to are trusted.** A malicious SSH server,
  herdr or herdr-core can show you false content or a misleading link in the
  login banner. Findings that need a compromised server are out of scope.
- **A rooted or compromised phone.**
- **The unlocked phone.** The app has no lock of its own: whoever can use
  the unlocked phone can connect to the saved hosts.
- **The Linux desktop build**, which is for development only.
