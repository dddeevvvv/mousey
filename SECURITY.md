# Security

Mousey reads your keyboard and trackpad, and it can install a helper that runs as root. This page says what protects you and what does not, so you can decide whether to trust it.

## Report a vulnerability

Use **Report a vulnerability** on this repository's **Security** tab. Do not open a public issue. Only the latest release gets fixes.

## What the app can do on your Mac

- **Read input.** With the Accessibility permission, the app reads all keyboard and trackpad input while you control the other Mac. While input stays on this Mac, its event tap asks for pointer movement only and does not receive keys.
- **Send input.** On the controlled Mac, the app posts the events it receives, which can type and click anything you could.
- **Run a helper as root.** This happens only if you turn on **Smooth Wi-Fi**. The helper is at `/Library/PrivilegedHelperTools/io.github.imsumitkumar.mousey.awdl-helper`. It runs `ifconfig awdl0 up` or `ifconfig awdl0 down`, and it reads no commands. Only your own user account can connect to its socket, and any data sent to that socket ends the connection.

## What protects you

- **Pairing.** Each Mac makes an X25519 key. One Mac commits to its key before it sees the other's, and both Macs show a 6-digit code derived from both keys. Someone in the middle has one chance in a million per attempt. The controlled Mac allows one attempt every 2 seconds and 10 in total, then stops listening until a person presses **Try again**, so a full run gives one chance in 100,000. A code expires after 5 minutes.
- **Saying yes.** A Yes trusts whoever is on the other end of that Mac's own connection. Press Yes only when the other Mac shows the same digits. If it shows an error or no code, press No. A Mac's name appears on this screen, and the other side chooses it, so a name keeps at most two digits.
- **Encryption.** The input link uses DTLS and the clipboard link uses TLS 1.2. Both ends accept only `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` and drop a session on any other suite, so a recording stays unreadable even if someone gets the key later. The clipboard has its own key, derived from the pairing key.
- **Key storage.** Each Mac derives the pairing key on its own and keeps it in the login Keychain. The key is never sent, and the 6-digit code is never the key.
- **No server.** No server sits between your Macs, and no account exists.
- **Release builds.** The test modes that post events exist only in debug builds. Release builds use the hardened runtime, which stops other programs loading code into the app, where it would hold the app's permissions.
- **Password fields.** macOS hides keystrokes while a field that turns on Secure Input has focus. If that lasts about half a second while you control the other Mac, control returns to the keyboard Mac, so what you type in that field cannot go to the wrong Mac.
- **Clipboard limits.** Sharing is off until you turn it on, on each Mac. Items move only as input crosses, and the receiving Mac accepts one item per crossing, for up to 10 seconds. Text with control characters is refused. Links must be `http`, `https`, or `mailto`. Files never move.
- **Updates.** The app asks GitHub for the latest version number and opens a fixed release page. It shows a version only if it is digits and dots. It downloads and installs nothing, because an app that can read keystrokes must not replace itself on the word of a server.

## What it does not protect against

- **A compromised paired Mac.** Pairing is trust. A compromised keyboard Mac can type anything on the controlled Mac. With clipboard sharing on, it can also read the controlled Mac's clipboard whenever it chooses, because it decides when input crosses. A compromised controlled Mac can put a harmful command on the keyboard Mac's clipboard each time you return, so look before you paste into Terminal.
- **Passwords typed outside a secure field.** A prompt that does not turn on Secure Input gets no protection, so a password typed there while you control the other Mac goes to the other Mac. A `sudo` prompt in Terminal can be one.
- **Clipboard content.** A password copied from an ordinary app travels when clipboard sharing is on. Only items that a password manager marks as concealed stay behind, and this has not been tested against real password managers.
- **Malware already running as you.** It could replace the app, because a copy in **Applications** can be changed without an administrator password. It could also replace the helper inside the app before you approve the password prompt that installs the helper. With the helper installed, it could keep AWDL off, which stops AirDrop and other features that use it.
- **A bad download.** Builds are self-signed and not notarized, so macOS does not vouch for them. You trust this repository and its release page. If macOS asks for Accessibility again after an update, stop, because that download may not be signed by this project. To avoid this trust, read the code and build it yourself.
- **Other networks.** The controlled Mac listens on every network interface, which can include a VPN. Only the paired key gets past the handshake, and pairing needs a person to say yes, but a firewall-minded reader should know the ports are not limited to the local network.
- **Future macOS changes.** The app relies on one private call and on the format of macOS's event bytes.

## How it has been checked

Automated tests cover the logic, including the pairing state machine and simulated network loss. The end-to-end self-test runs the real encrypted link on loopback. AI reviewers have read the pairing, transport, clipboard, helper, and update code, their blocking findings were fixed, and another AI reviewer then tried to defeat those fixes.

Nobody outside the project has audited this code, and most of it was written with Claude Code, an AI tool. Treat it as early software.
