## Choose from Contacts actually works

- Picking someone from your contacts did nothing. On iPhone the picker was presented as a SwiftUI sheet, which a system contact picker cannot be — it appeared, but never reported back what you tapped. It is now presented the way iOS expects.
- Even once it appeared, tapping a person was ignored. Manas asked iOS to always drill into a specific number, but that request is only honored if the app also handles a whole-person tap — and it didn't, so iOS discarded the request and then had nowhere to send your choice. Both paths are handled now: one number picks in a single tap, several numbers let you choose which.
- On Mac the picker never opened at all. It was anchored to a zero-sized point, and a popover cannot attach to nothing.
