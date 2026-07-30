## Manas updates itself from here on

- Manas now checks for new versions once a day and installs them in the background, so the next launch is simply current. Nothing to download, no prompt to dismiss. There's a "Check for Updates…" item under the Manas menu if you'd rather not wait.
- **This is the last version you have to install by hand.** Updating is only possible from a build that already carries the updater, so 0.2.8 and earlier need one manual pass — 0.3.0 onwards takes care of itself.
- Updates are signature-checked twice over: the feed is EdDSA-signed and the downloaded build has to carry the same Developer ID as the one it replaces, which is also what keeps your Full Disk Access grant attached.

## The check-in reads more of your day

- Messages now covers SMS and RCS, not just iMessage.
- A busy day no longer hides itself. The check-in reads a capped slice of each day's messages, and that slice used to be the first 80 — so on a chatty morning the judge's view froze somewhere in the middle of the night. It now reads the most recent ones.
- The judge pulls commitments out of your conversations: a promise you made, or a request pointed at you that you took on. They arrive in Discovered like any other suggestion, one tap from becoming a todo. Only things still outstanding show up.

## Smaller things

- Finished todos drop to the bottom of their group instead of sitting where you left them, with a rule marking the line. The day's record stays visible, the live list stays short.
- The iPhone app matches the desktop's colors again in both light and dark mode.
