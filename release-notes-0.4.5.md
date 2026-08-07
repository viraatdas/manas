## Shared groups reach the people you shared them with

- If someone you shared a group with saw nothing at all, this is the fix. Their app was sending back the group's record on every sync, the server was refusing it — only the owner may write that record — and the refusal stopped the whole sync before their todos were ever fetched. It looked exactly like an empty group, on every launch, with nothing to say anything had gone wrong. Each device now only sends what it's allowed to write.

## People have names, not digits

- Someone with no name showed up as the last two digits of their phone number. Tap anyone in the share panel to name them, and their avatar becomes their initials for everyone in the group.
- Sharing from your contacts already brings their name across, so anyone you invite that way has initials from the start. This is for the people you shared with before that, and for fixing a name that came through wrong.
