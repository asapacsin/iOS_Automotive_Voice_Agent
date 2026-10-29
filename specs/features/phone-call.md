# F-19 Phone call with confirmation

**Android status:** IMPLEMENTED (JVM). CALL-NOSIM-001 NOT_RUN; CALL-REAL-001 HUMAN.
**Depends on:** F-09

## 1. Purpose
Call a contact by voice after an explicit confirmation turn.

## 2. User-facing behaviour
打电话给妈妈 → 「要打给妈妈吗？」 → 是 → dials.

## 3. Preconditions
- A device that can place calls (`canPlaceCalls`); otherwise `NO_TELEPHONY`.
- Contacts permission (`NSContactsUsageDescription`, PROPOSED); denied → `CONTACTS_PERMISSION_DENIED`.

## 4. Inputs and outputs
`place_call(contact, confirmed?)`:
- first call (no `confirmed`): look up the contact → `status: confirm_required` (one match) or
  `ambiguous` with the matching names (several); nothing is dialled;
- second call `confirmed=true` for the same contact within the window → dial.
Contact records: display name + phone numbers.

## 5. State transitions
idle → awaiting_confirmation (contact, time) → dialling → idle. A different contact or an expired window
returns to idle.

## 6. Events and triggers
`place_call` tool calls; the driver's yes/no answer (a new turn).

## 7. Dependencies and external services
Contacts port (CNContactStore) and telephony port opening `tel://`; iOS then shows its own call
confirmation (PROPOSED). CallKit is not used for outgoing calls.

## 8. Error handling and recovery
| Case | Code |
|---|---|
| Not found | `CONTACT_NOT_FOUND` |
| Several matches | status `ambiguous` (asks which) |
| `confirmed=true` without a prior confirm | `CALL_NOT_CONFIRMED` |
| Confirmation too old | `CONFIRMATION_STALE` |
| Opening the URL failed | `CALL_FAILED` |
| No telephony | `NO_TELEPHONY` |
She never says she is calling before the dial result is ok (I-1). Numbers are not logged (I-8).

## 9. Concurrency, cancellation, timeouts
Short confirmation window (Android value, ported in the tool executor); one pending confirmation at a
time; a new `place_call` replaces it.

## 10. Acceptance criteria (iOS)
- First call returns confirm_required; only `confirmed=true` for the same contact within the short window dials.
- No telephony → `NO_TELEPHONY`.

## 11. Existing Android tests
`T/PhoneCallToolTest`.

## 12. Source references (Android)
`A/PhoneCallTool.kt:48-50,62,73,97-109`; `A/AndroidContacts.kt:30-33`; `A/phone/PhoneProvider.kt:15`; `A/ToolFailureAdvice.kt:38`.

## 13. Implementation constraints
None beyond the contracts.

## iOS notes (PROPOSED unless labelled)
`CNContactStore` + `tel://` URL opens the system call UI (user must confirm) — PROPOSED; CallKit not needed for outgoing PSTN. iPad/no SIM → NO_TELEPHONY.
