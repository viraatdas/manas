## Sign in on either device first

- Desktop and iPhone now use the same Manas-branded phone verification flow.
- A verified phone number creates or recovers its sync account automatically, so mobile-first and desktop-first behave the same.
- Hardens the server exchange so a verified code can only create a session for the phone number Stytch actually authenticated.
- Restores the App Review test sign-in without sending a real SMS.
