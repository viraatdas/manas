## A group you shared now actually reaches them

- If you shared a group with someone and it never appeared on their phone, this is the fix — and it was never their fault. A number typed as `(309) 826-4765` was stored without its country code, while the account they signed in with is `+1 309 826 4765`. Those are one person, but they were two different identities, so the server hid the group from the only people it had been opened up to. It looked complete to you and empty to them, with nothing on either side to say why.
- Every number you type now resolves to the same identity the server uses, borrowing the country code from the number you're signed in as. If a number's country genuinely can't be worked out, Manas asks for the `+` instead of quietly saving something that reaches nobody.
- Groups already shared under the old form have been repaired. You don't need to re-share anything.

## Names come from your contacts

- People in a shared group show their initials, drawn from your own address book. Someone saved as Krithik shows KR, whether or not they ever set a name in Manas.
- The last-two-digits avatars are gone. A shared list showing "65" and "44" for people it had never heard of read as initials, because a pair of characters in a circle always does. Someone your address book doesn't know now gets a neutral silhouette instead of a wrong-looking name.
- Contacts are read on your device, drawn, and forgotten. No name is ever written to a group or sent to the server, so the same group correctly reads KR on a phone that knows Krithik and stays unnamed on one that doesn't.

## Hourly check-ins stop timing out

- More than half of the automatic check-ins were failing. The pass had 180 seconds to read a full day of transcripts, and that job's runtime swings hard — the same day measured two minutes on one attempt and still hadn't finished after ten on the next. Nothing waits on this pass, so it now has room to finish instead of being cut off near the median.
- When a check-in does fail, Manas records which kind of failure it was, so a run of them is visible rather than silent. Only the category is recorded — never the error text, which quotes your own todos back.
