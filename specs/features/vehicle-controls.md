# F-11 Vehicle controls (simulated)

**Android status:** IMPLEMENTED, SIMULATED ONLY (no VHAL/CarPropertyManager).
**Depends on:** F-09

## 1. Purpose
Let the driver adjust climate, seat and windows by voice; state is simulated in memory.

## 2. User-facing behaviour
空调开了/温度调低了/座椅降低了一档 etc., with on-screen chip; values read back after the change.

## 3. Preconditions
None.

## 4. Inputs and outputs
Tools `control_climate` (power, set/change temperature, set/change fan), `control_seat` {adjust_height, set_height, get_state; seat driver/passenger}, `control_window` {open, close, set, adjust, get_state; window; value}. Results include `limit_reached`.

## 5. State transitions
In-memory vehicle state.

## 6. Events and triggers
Tool calls.

## 7. Dependencies and external services
None (simulator). Fault injection: UNSUPPORTED, UNAVAILABLE, PERMISSION_DENIED, EXECUTION_FAILURE.

## 8. Error handling and recovery
Errors are ok=false with code.

## 9. Concurrency, cancellation, timeouts
Synchronous.

## 10. Acceptance criteria (iOS)
- Climate/seat/window results identical to Android for the same call sequence (golden-file unit tests).
- Sunroof request refused (`UNSUPPORTED_BODY_PART`).

## 11. Existing Android tests
`T/vehicle/ClimateToolHandlerTest`, `SeatToolHandlerTest`, `WindowToolHandlerTest`, `ClimateVoiceFlowTest`, `ActionAnnouncementTest`, `ToolCallGuardSunroofTest`, `ToolCallGuardDriverWindowTest`.

## 12. Source references (Android)
`A/vehicle/VehicleControlProvider.kt`; `simulator/src/main/kotlin/com/novadrive/simulator/SimulatedVehicleControl.kt:19,35`; `A/vehicle/*ToolHandler.kt`; `A/tools/BodyDomain.kt:29`.

## 13. Implementation constraints
Keep `BACKEND_LABEL=simulated` visible so nobody mistakes it for a real car.

## iOS notes (PROPOSED unless labelled)
Portable (A). CarPlay gives no climate/seat/window access (PROPOSED; verify OQ-IOS-6).
