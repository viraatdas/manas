## Signing in on one device no longer signs out the other

- Signing in could quietly sign every other device out. After that, sync kept retrying a session that no longer existed and showed "Invalid Refresh Token" without ever recovering. That no longer happens.
- If your session does end, Manas now says so and asks you to sign in again, with your number already filled in. Everything you changed while sync was paused is kept and syncs once you're back, so nothing gets overwritten.
- A sign-in token the server rejects is now refreshed and retried straight away, instead of failing again every minute.
