# F-19 Phone call with confirmation

**Android status:** IMPLEMENTED (JVM). CALL-NOSIM-001 NOT_RUN; CALL-REAL-001 HUMAN.
**Depends on:** F-09

## 1. Purpose
Call a contact by voice after an explicit confirmation turn.

## 2. User-facing behaviour
打电话给妈妈 → 「要打给妈妈吗？」 → 是 → dials.

## 3. Preconditions
See depends-on contracts.

## 4. Inputs and outputs
See refs.

## 5. State transitions
See contracts.

## 6. Events and triggers
Tool call or UI event.

## 7. Dependencies and external services
See contracts/api-contracts.md.

## 8. Error handling and recovery
Errors are ok=false results with codes; see refs.

## 9. Concurrency, cancellation, timeouts
See contracts.

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
