## Double-tapping Caps Lock works again

- Quick capture stopped answering to Caps Lock after an update, and there was no way to get it back. macOS ties Accessibility permission to an app's signature, and every update changes it — so the permission quietly lapsed, and Manas never asked for it again because it had already asked once, months earlier. It now notices a permission it used to hold has gone and asks for it back.
- Granting the permission also takes effect immediately. Manas used to need a quit and relaunch before Caps Lock started working, because the key listener had already been set up without it.

**If Caps Lock still does nothing after this update**, grant it once in System Settings → Privacy & Security → Accessibility. Manas will ask on its own, and after this version a future update won't cost you the permission silently again.

## Share a group from your contacts

- Sharing a group no longer means typing a phone number in by hand. "Choose from Contacts" opens your contact list and you pick the person — and the number you tap is the one it shares to, so someone with a work line and a mobile doesn't come down to a coin flip.
- Their name comes across with them, so their avatar shows initials instead of digits. A name you already typed for them is kept.
- Typing a number still works, for people who aren't in your contacts.
- This uses the system contact picker, which hands back only the number you tap. Manas never reads your address book, and macOS and iOS ask you for no permission at all.
