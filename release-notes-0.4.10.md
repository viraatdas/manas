## Manas can actually read your Contacts now

- On Mac, names never appeared — and no permission prompt ever did either. Manas asks for Contacts through the hardened runtime, which needs the request declared in the app's entitlements as well as in its usage description. It only had the second, so macOS refused the request before it ever became a prompt: no dialog, no denial, nothing in Privacy & Security to switch on, and every member of a shared group reading as a phone number with no way to fix it.
- With that declared, the prompt appears the first time a shared group needs a name, and people show up as their names. If you've already said no, Privacy & Security › Contacts has the switch, and the share panel now links straight to it.
- Names are still read on your device, drawn, and forgotten. Nothing is uploaded.
