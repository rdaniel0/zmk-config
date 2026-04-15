# MCU Freeze Investigation

## Problem

The central (right) half of the Dactyl split keyboard intermittently freezes
mid-keypress. The keyboard becomes completely unresponsive, requiring a physical
reset. A key may get "stuck" because the press was registered but the release
never processed.

## Hardware

- nice!nano v2 (nRF52840) on both halves
- Right half = central (BLE role configured in `Kconfig.defconfig`)
- Left half = peripheral

## Firmware Changes (commit 4212f5e)

Enabled crash diagnosis and increased stack sizes:

```
CONFIG_HW_STACK_PROTECTION=y
CONFIG_EXCEPTION_STACK_TRACE=y
CONFIG_ZMK_BLE_THREAD_STACK_SIZE=1536       # was 768
CONFIG_ZMK_SPLIT_BLE_CENTRAL_SPLIT_RUN_STACK_SIZE=1024  # was 512
CONFIG_SYSTEM_WORKQUEUE_STACK_SIZE=2560      # was 2048
```

## Log Analysis (2026-03-24)

Captured with `zmk-usb-logging` snippet on the central half.

### Freeze Sequence

The MCU stopped between `position_state_changed_listener` and
`zmk_keymap_apply_position_state` while processing a local key release:

1. Peripheral notification arrives (position 0 press) — captured by combo system
2. Combo times out ~50ms later, releases position 0, HID report sent
3. **26ms later**: local kscan fires position 18 press — fully processed
4. **28ms later**: peripheral notification (position 0 release) — processed
5. **43ms later**: local kscan fires position 18 release
6. `position_state_changed_listener: 18 bubble` — **last log line, MCU dies here**

No MPU fault or stack trace was emitted despite `HW_STACK_PROTECTION=y`.

### Session Stats

- 31,589 log lines over ~28 minutes of uptime
- 1,750 peripheral BLE notifications
- 166 MCU time gaps >400ms (most are idle periods between typing)
- 0 errors or warnings logged
- 0 BLE disconnects

## ZMK Threading Model (source analysis)

All event processing converges on the **system workqueue** (single thread):

| Source | ISR/Callback Context | Work Queue |
|--------|---------------------|------------|
| BLE peripheral notify | BLE RxThread → `k_msgq_put` + `k_work_submit` | System workqueue |
| Local kscan | kscan ISR → `k_msgq_put` + `k_work_submit` | System workqueue |
| Combo timeouts | `k_work_schedule` | System workqueue |
| Split central run | `k_work_submit_to_queue` | Dedicated `split_central_split_run_q` |

### Key Findings

- **No mutexes or locks anywhere** in the event processing path. ZMK relies
  entirely on single-threaded execution on the system workqueue.
- **Combo system has unprotected global state** (`pressed_keys[]`,
  `candidates[]`, `active_combo_count`) — safe on single-core nRF52840 only.
- **Event manager dispatches synchronously** — a blocking listener stalls
  everything.
- **Deep call stack** on peripheral events: `work_callback` → `event_handler`
  → `event_manager` → `combo_listener` → `keymap_apply` → `behavior_pressed`
  → `hid_press` → `endpoint_send`.

### Likely Cause

Not a classical deadlock (no locks exist). Most probable:

1. **Hard fault not captured** — USB log buffer wasn't flushed before MCU
   halted. The fault handler tries to log over USB but the USB subsystem may
   not be in a state to transmit.
2. **Kernel panic/assertion** — halts CPU without going through the log backend.
3. **Stack overflow not caught by MPU** — the MPU guard region is only 32 bytes
   on Cortex-M4. A large stack frame could jump over it entirely.

## Log Analysis (2026-03-30) — Second capture

22-hour session with thread analyzer enabled (`CONFIG_THREAD_ANALYZER=y`).

### Freeze Sequence

The MCU stopped at the same point — `position_state_changed_listener` processing
a peripheral key release after a combo timeout:

1. Position 31 (peripheral, mod_tap/space) pressed and released via hold-tap
2. `on_hold_tap_binding_released: 31 cleaning up hold-tap`
3. **313ms later**: peripheral notification arrives (position 2 press)
4. Combo captures it, times out 50ms later, releases position 2
5. `on_keymap_binding_pressed: position 2 keycode 0x70007` — HID report sent
6. `combo_timeout_handler: ABOUT TO UPDATE IN TIMEOUT`
7. **32ms later**: peripheral notification (position 2 release — all zeros)
8. `peripheral_event_work_callback` fires
9. `position_state_changed_listener: 2 bubble (no undecided hold_tap active`
   — **log truncated mid-line, MCU dies**

The log cuts off mid-string — the `)` at the end of the debug message is missing.
This means the MCU froze during the `printk`/`LOG_DBG` call itself, or the USB
buffer never flushed the rest.

### Session Stats

- 363,336 log lines over ~22 hours (31:48:21 uptime)
- 0 errors or warnings
- 0 stack overflow faults
- 2 BLE disconnects (both reason 0x08 = supervision timeout, both reconnected)
- No reboots

## Log Analysis (2026-03-30, second capture) — Third freeze

~2-hour session captured with USB monitoring enabled.

### Freeze Sequence

Different from previous freezes — no combo timeout involvement:

1. Normal typing: position 18 (local kscan, 'e') pressed and released cleanly
2. **1.6s gap** (idle)
3. Peripheral notification: position 31 (mod_tap/space) press
4. Hold-tap decides tap (balanced decision moment key-up)
5. `on_keymap_binding_pressed: position 31 keycode 0x7002C` — HID report sent
6. `on_keymap_binding_released: position 31 keycode 0x7002C` — HID report sent
7. `on_hold_tap_binding_released: 31 cleaning up hold-tap` — **last log line**

Log ended cleanly (no mid-line truncation). No stuck keys. MCU just stopped
producing output after a completed hold-tap release.

### Session Stats

- 166,060 log lines over ~2 hours (05:40:17 uptime)
- 14,551 HID reports, 3,350 thread analyzer snapshots
- 0 errors or warnings, 0 BLE disconnects
- No USB events until the freeze itself

### Thread Analyzer (consistent with previous captures)

- **logging** at 84% (120 bytes free) `***`
- **sysworkq** at 61% (984 bytes free)
- No thread growth detected — all values identical to previous session

### Comparison across all freezes

| | March 24 | Mar 30 (1st) | Mar 30 (2nd) |
|---|---|---|---|
| Uptime at freeze | 12:07:32 | 31:48:21 | 05:40:17 |
| Last function | `position_state_changed_listener` | `position_state_changed_listener` | `on_hold_tap_binding_released` |
| Combo timeout before | Yes | Yes | **No** |
| Stuck key | Yes (pos 18) | Yes (pos 2) | **No** |
| Log truncation | Clean end | Mid-line | Clean end |
| MPU fault | No | No | No |
| USB disconnect | No | No | **Yes (MCU rebooted)** |

## Revised Theory

The combo timeout is **not** the sole trigger — the third freeze had no combo
involvement at all. The common thread across all three freezes:

1. **All involve peripheral (left half) BLE events** being processed on the
   central's system workqueue
2. **The logging thread is critically close to overflow** (84%, 120 bytes free)
   across all sessions — consistent, not growing
3. **No MPU fault is ever logged**, suggesting either the fault handler can't
   run (stack overflow in ISR context?) or a watchdog is resetting the MCU

The third freeze also revealed a **USB re-enumeration** (device number 40 → 41),
meaning the MCU actually **rebooted** rather than just hanging. This is new —
previous freezes left the USB device enumerated but unresponsive.

## Firmware Change: Doubled Stack Sizes (commit 1d17436)

To test the stack overflow hypothesis:

```
CONFIG_SYSTEM_WORKQUEUE_STACK_SIZE=4096     # was 2560 (61% used / 984 free)
CONFIG_LOG_PROCESS_THREAD_STACK_SIZE=1536   # was 768 (84% used / 120 free)
```

If freezes persist with these changes, stack overflow can be ruled out and
investigation should focus on the BLE peripheral event processing code path
itself.

## Thread Analyzer Data (last snapshot before freeze)

Captured 27 seconds before the freeze (11:48:28, freeze at 11:48:55):

| Thread | Used | Total | Usage % | Unused |
|--------|------|-------|---------|--------|
| **sysworkq** | 1504 | 2560 | 58% | 1056 |
| **logging** | 648 | 768 | **84%** | **120** |
| BT LW WQ | 936 | 1408 | 66% | 472 |
| BT RX pri | 328 | 512 | 64% | 184 |
| ISR0 | 832 | 2048 | 40% | 1216 |
| BT RX WQ | 928 | 2304 | 40% | 1376 |

The **logging thread has only 120 bytes of headroom**. The freeze log cuts off
mid-line (`hold_tap active` missing closing `)`), which could mean the logging
thread overflowed while formatting the debug message. The sysworkq has 1056
bytes unused in the high watermark, but the freeze may push it deeper than
any prior call.

## Log Analysis (2026-03-31) — Fourth freeze (new firmware with doubled stacks)

Firmware with `CONFIG_SYSTEM_WORKQUEUE_STACK_SIZE=4096` and
`CONFIG_LOG_PROCESS_THREAD_STACK_SIZE=1536` (commit 1d17436).

### Stack overflow ruled out

Thread analyzer confirms ample headroom on all threads:

| Thread | Used | Total | Free | Usage % |
|--------|------|-------|------|---------|
| sysworkq | 1488 | 4096 | **2608** | 36% |
| logging | 648 | 1536 | **888** | 42% |

No threads near overflow. No growth. **Doubling the stacks made no difference —
the freeze is not caused by stack overflow.**

### Freeze Sequence — identical pattern

1. `combo_timeout_handler: ABOUT TO UPDATE IN TIMEOUT` (after position 11 release)
2. Peripheral notification: position 13 press → captured by combo
3. Combo times out, releases position 13, HID report sent
4. `combo_timeout_handler: ABOUT TO UPDATE IN TIMEOUT`
5. **Dead.** Log ends cleanly, no truncation.

### Session Stats

- 136,509 log lines over ~3 hours (17:15:26 uptime)
- 11,649 HID reports, 4,893 thread analyzer snapshots
- 0 errors/warnings, 0 BLE disconnects, no USB events
- Stuck key: position 13 (keycode `0x70016` / 's')

### Updated comparison across all freezes

| | Mar 24 | Mar 30 (1st) | Mar 30 (2nd) | **Mar 31** |
|---|---|---|---|---|
| Firmware | original | original | original | **doubled stacks** |
| Uptime | 12:07:32 | 31:48:21 | 05:40:17 | **17:15:26** |
| Last log line | `position_state_changed_listener` | `position_state_changed_listener` | `on_hold_tap_binding_released` | **`combo_timeout_handler: ABOUT TO UPDATE`** |
| Combo timeout before | Yes | Yes | No | **Yes** |
| Stuck key | Yes | Yes | No | **Yes** |
| Log truncation | Clean | Mid-line | Clean | **Clean** |
| USB disconnect | No | No | Yes (reboot) | **No** |
| sysworkq headroom | 1056 | 984 | 984 | **2608** |
| logging headroom | 120 | 120 | 120 | **888** |

## Confirmed Root Cause Area: `combo_timeout_handler`

3 of 4 freezes end with `combo_timeout_handler: ABOUT TO UPDATE IN TIMEOUT` as
the last log line. The code that executes **after** this log message is the crash
site. The one freeze without combo involvement (Mar 30 2nd) may have been a
different trigger or a race in the same code.

## Source Code Analysis: `combo.c` crash site

The freeze occurs at `combo_timeout_handler` (combo.c:475) → `update_timeout_task`
(combo.c:486). Two bugs identified, with two competing theories about which is the
primary crash cause.

### Bug 1: LONG_MAX vs LLONG_MAX type mismatch (sentinel value)

`first_candidate_timeout()` (line 206, 209) returns `LONG_MAX` as its "no timeout"
sentinel. `update_timeout_task()` (line 411) checks `if (first_timeout == LLONG_MAX)`.

On 32-bit ARM (nRF52840): `LONG_MAX` = 2^31-1 (2,147,483,647), `LLONG_MAX` =
2^63-1. These are **never equal**, so the cancel-and-return path is dead code.

The consequence: when there are no combo candidates (after cleanup, or when
`pressed_keys_count == 0`), instead of cancelling the timer, the code falls through
to:

```c
k_work_schedule(&timeout_task, K_MSEC(first_timeout - k_uptime_get()));
//                                     2,147,483,647 - uptime_ms
```

The delta (~2 billion ms) is converted to kernel ticks via `K_MSEC()`. At
`CONFIG_SYS_CLOCK_TICKS_PER_SEC=32768` (nRF52840 default):
`~2,086,000,000 * 32768 / 1000 ≈ 68 trillion ticks` — this **overflows** any
32-bit intermediate in the tick conversion macro, potentially producing a
negative or zero timeout. A zero/negative timeout causes the work to fire
immediately, re-entering `combo_timeout_handler` in a tight loop.

After ~24.8 days of uptime, `LONG_MAX - k_uptime_get()` itself goes negative,
which may cause `K_MSEC()` to produce undefined behaviour.

### Bug 2: Re-entrant combo state modification

The `combo_timeout_handler` flow involves synchronous event dispatch:

```
combo_timeout_handler()
  → cleanup()
    → release_pressed_keys()
      → ZMK_EVENT_RELEASE / ZMK_EVENT_RAISE  (synchronous!)
        → event_manager dispatches to all listeners
          → position_state_changed_listener()  (RE-ENTRANT!)
            → position_state_down()
              → capture_pressed_key()  (modifies pressed_keys[])
              → update_timeout_task()  (modifies timeout_task_timeout_at)
  → update_timeout_task()  (reads potentially stale state)
```

When `cleanup()` → `release_pressed_keys()` re-raises captured position events,
those events are dispatched **synchronously** through the event manager back into
the combo listener. If a re-raised event triggers `position_state_down`, it
modifies the same global state (`pressed_keys[]`, `candidates[]`,
`timeout_task_timeout_at`) that `combo_timeout_handler` is in the middle of using.

When control returns to `combo_timeout_handler` line 486, the state it relies on
has been modified by the re-entrant call. `update_timeout_task` may then:
- Read `pressed_keys[0].data.timestamp` values written by the re-entrant path
- Compute a negative timeout if the re-entrant path altered `candidates[]`
- Schedule a work item with undefined delay
- Trigger a Zephyr kernel fault

### Which bug causes the freeze? Two theories

**Theory A: Tick overflow via LONG_MAX sentinel (Bug 1 primary)**

Every time `combo_timeout_handler` fires and cleans up (no remaining candidates),
Bug 1 causes `update_timeout_task` to schedule with a ~2 billion ms delay. If the
`K_MSEC()` tick conversion overflows to zero or negative, the work fires
immediately, creating an infinite tight loop on the system workqueue. This starves
all other work (BLE, HID, logging) — explaining the freeze with no fault logged.

Evidence for:
- 3 of 4 freezes end exactly at "ABOUT TO UPDATE IN TIMEOUT" → `update_timeout_task`
- No MPU fault or assertion — consistent with an infinite loop, not a memory fault
- Clean log endings (no mid-line truncation in 3 of 4) — the MCU is alive but busy

Evidence against:
- The bug fires on every combo timeout, not just at the freeze moment — so why
  doesn't it freeze every time? Possibly depends on tick arithmetic edge cases.

**Theory B: Re-entrant state corruption (Bug 2 primary)**

The synchronous event dispatch creates a re-entrancy window where
`update_timeout_task` operates on state modified by a nested `position_state_down`
call. The corrupted state produces a bad timeout value → kernel fault or loop.

Evidence for:
- All freezes involve the combo/event processing path
- Sometimes involves peripheral events (they contribute captured keys that
  get re-raised back through the combo listener)
- Sometimes truncates log mid-line (hard fault) vs clean end (loop)

Evidence against:
- Re-entrancy is by design in ZMK's single-threaded event model — `release_pressed_keys`
  is called from `cleanup` in multiple places, not just the timeout handler
- Mar 30 (2nd) freeze had no combo involvement at all

### Related ZMK issues

- **zmkfirmware/zmk#3100**: Sticky shift + combo → hold-tap → macro crash (open)
- **zmkfirmware/zmk#3262**: Dongle crash traced to commit `9e36ebd` (open)
- **zmkfirmware/zmk#1944/#1945**: Previous combo timeout fix (closed)
- No existing issue reports the LONG_MAX/LLONG_MAX mismatch

## Plan: Isolate which bug causes the freeze

Both bugs are real and should be fixed upstream regardless. Testing them
one at a time to determine which (or both) causes the freeze.

### Round 1: Fix Bug 1 only (LONG_MAX → LLONG_MAX) — DONE, freeze persists

Applied LLONG_MAX fix to fork (rdaniel0/zmk#fix/combo-long-max). Freeze
occurred after only 17 minutes (2026-03-31 22:50). Same pattern:
`combo_timeout_handler: ABOUT TO UPDATE` → events processed → dead.

**Result: Bug 1 is not the crash cause.** The fix is still correct and should
go upstream, but it doesn't explain our freeze.

### Round 2: Add CONFIG_ASSERT=y (test Bug 2) — DONE, no assertion fired

Enabled `CONFIG_ASSERT=y` + `CONFIG_ASSERT_LEVEL=2`. Freeze occurred after
~36.5 hours (2026-04-02 11:33). **No assertions fired.** The
`pressed_keys_count > 0` assertion in `filter_timed_out_candidates` was never
triggered.

**Result: Bug 2's re-entrancy theory is weakened** — the specific assertion
path wasn't hit. However, re-entrancy could still occur in a path that doesn't
trigger this assertion.

### Fifth freeze (2026-04-02) — new crash pattern

Session: ~36.5 hours, 534k+ log lines, 0 errors/warnings, 0 BLE disconnects.

Crash sequence — **no combo timeout involved**:

1. Peripheral notification: position 11 release — processed cleanly
2. Local kscan: position 26 press — captured by combo system
3. Local kscan: position 19 release — triggers combo `release_pressed_keys`
   for position 26 (combo timed out due to non-matching key release)
4. Position 26 keypress processed via `zmk_keymap_apply_position_state`, HID
   report sent
5. Position 19 release processed via `zmk_keymap_apply_position_state`, HID
   report sent
6. **Dead.** Log ends cleanly after `zmk_endpoint_send_report`.

Key differences from previous freezes:
- No `combo_timeout_handler: ABOUT TO UPDATE` in crash context
- `release_pressed_keys` triggered from `position_state_changed_listener`
  (key-up path), not from `combo_timeout_handler`
- No stuck keys (combo released position 26 before the freeze)
- Longest session yet (36.5h vs previous max 31h)

User context: normal typing on default layer, no intentional combo activation,
no modifier held at time of freeze. Modifiers had been used within prior 5 min.

### Updated comparison across all freezes

| | Mar 24 | Mar 30 (1st) | Mar 30 (2nd) | Mar 31 (R1) | Mar 31 (R1b) | **Apr 2 (R2)** |
|---|---|---|---|---|---|---|
| Firmware | original | original | original | +stacks | +LLONG_MAX | **+ASSERT** |
| Uptime | 12h | 31h | 5.6h | 17h | 17min | **36.5h** |
| Last function | `pos_state_listener` | `pos_state_listener` | `hold_tap_released` | `combo_timeout ABOUT TO UPDATE` | `combo_timeout ABOUT TO UPDATE` | **`endpoint_send_report`** |
| Combo timeout | Yes | Yes | No | Yes | Yes | **No** |
| `release_pressed_keys` visible | Yes | Yes | No | Yes | Yes | **Yes** |
| Stuck key | Yes | Yes | No | Yes | No | **No** |
| Assertion fired | n/a | n/a | n/a | n/a | n/a | **No** |

### Sixth freeze (2026-04-02, Round 3 instrumented) — combo system exonerated

Session: ~2.6 hours, DIAG-instrumented combo.c. Freeze at 17:54:16,
USB disconnect confirmed 28s later at 17:54:44.

Crash context with full DIAG trace:
1. Peripheral notification: position 10 (key 'n') press — **no combo candidates**
   (`pos_down pos=10 no candidates, bubbling`), processed normally
2. Local kscan: position 19 release — combo cleanup with `pressed=0`, nothing
   to release, bubbles to keymap
3. `zmk_keymap_apply_position_state` → `on_keymap_binding_released` → HID report
4. `zmk_endpoint_send_report: usage page 0x07` — **last log line**
5. 28s silence, then USB disconnect (user unplugged frozen device)

**The combo system completed all its work and returned cleanly.** Every DIAG
checkpoint was reached. No stuck keys. The freeze occurred **after** the combo
system, somewhere in:
- `zmk_endpoint_send_report` or its BLE/USB HID transport
- The system workqueue returning to idle after processing the event
- The BLE stack servicing the HID report

Also noted: two warnings earlier in the session:
- `Failed to release peripheral slot (-22)` at 16:26:54
- `Got battery level event for an out of range peripheral index`
These suggest BLE peripheral slot state corruption.

### Revised analysis

**The combo system is not the freeze cause.** The DIAG instrumentation proves
the combo code completes normally before every freeze. The combo-related
patterns in earlier freezes (combo timeout as last log line) were coincidental —
the combo timeout fires frequently during normal typing, so it often appears
in the last 30 lines by chance.

The actual freeze point is **after the full event processing chain completes**,
somewhere in:
- The BLE GATT HID report transmission path
- The system workqueue scheduler returning control after processing
- The BLE controller or softdevice

The peripheral slot warnings suggest BLE stack state corruption that may
eventually cause a hang.

## BLE Stack Analysis (2026-04-02)

### HID report send architecture

```
zmk_endpoint_send_report (system workqueue)
  → zmk_hog_send_keyboard_report (hog.c:338)
    → k_msgq_put(&zmk_hog_keyboard_msgq, K_MSEC(100))  // BLOCKS on sysworkq!
    → k_work_submit_to_queue(&hog_work_q, &hog_keyboard_work)
      → send_keyboard_report_callback (hog_work_q thread)
        → bt_gatt_notify_cb(conn, &notify_params)
```

### Three BLE issues identified

**Issue 1: Battery GATT handle leak** — `release_peripheral_slot()` (central.c:215)
resets position and behavior handles but NOT `batt_lvl_subscribe_params` or
`batt_lvl_read_params`. Stale subscriptions survive disconnect, causing GATT
state corruption on reconnect (matches zmkfirmware/zmk#3156).

**Issue 2: Double peripheral slot release** — three code paths can release the
same slot (create failure, connect error, disconnect callback). Second release
returns -EINVAL (-22), which is the warning we observed.

**Issue 3: Workqueue stall from blocking msgq_put** — `zmk_hog_send_keyboard_report`
calls `k_msgq_put(..., K_MSEC(100))` on the system workqueue. If the `hog_work_q`
consumer is stalled (e.g. `bt_gatt_notify_cb` blocking on a corrupted connection
from Issue 1), the queue fills and the system workqueue blocks. The recursive
retry on -EAGAIN could loop indefinitely.

**Related: zmkfirmware/zmk PR #3110** — documents a system workqueue deadlock in
split BLE code where `bt_gatt_notify()` blocks when called inline. Fix moves
notify to a managed work queue. Our Issue 3 is a similar pattern.

## Test A: Disable battery level fetching — DONE, freeze persists

Disabled `CONFIG_ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_FETCHING=n` as of
2026-04-03. Freeze occurred 2026-04-07 after ~92 hours wall clock / ~19.5h
MCU uptime. Longest session yet (previous max 36.5h wall clock).

- 0 errors/warnings (no peripheral slot warnings with battery fetching off)
- No stuck keys, combo system clean (DIAG confirms)
- Log truncated mid-line: `[12:04:06.435] [` — MCU died during log write
- Freeze point: after `on_keymap_binding_released` for position 31 (space
  mod_tap on peripheral), `hid_listener_keycode_released`, then truncation

**Result:** Battery fetching is not the sole cause. The longer session
(~3x previous) may suggest it contributes to instability, or may be
coincidence. The peripheral slot warnings are gone, confirming they were
battery-related.

## Test B: Instrument HID send path — DONE, critical finding

Instrumented `zmk_endpoint_send_report`, `zmk_hog_send_keyboard_report`,
`send_keyboard_report_callback`, and `peripheral_event_work_callback` with
LOG_ERR DIAG traces. Freeze occurred after ~3h (2026-04-07).

### Critical finding: freeze between two consecutive log statements

```
[16:21:42.894] zmk_endpoint_send_report: usage page 0x07   ← LOG_DBG fires
                                                             ← DIAG: endpoint_send ... NEVER fires
```

The LOG_DBG at endpoints.c:251 executes, but the LOG_ERR on the very next line
(252) does not. The MCU cannot execute a single additional C statement after
the LOG_DBG call.

This rules out:
- Deadlock in HID send path (never reached)
- Deadlock in `k_msgq_put` (never reached)
- Deadlock in `bt_gatt_notify_cb` (never reached)
- Any combo system issue (already exonerated)

This points to:
- **The logging system itself** — LOG_DBG may trigger the logging thread to
  process/flush, and something in that path crashes or deadlocks
- **An interrupt or ISR** firing between the two log calls and never returning
- **A hard fault** during the LOG_DBG call that doesn't produce visible output

### Possible logging system deadlock

`LOG_DBG` on Zephyr queues a message to the logging subsystem's ring buffer.
If the ring buffer is full, the call may block waiting for the logging thread
to drain it. The logging thread runs on its own stack (1536 bytes, 39% used)
and writes to the USB CDC ACM backend. If the USB stack is stalled (e.g.
waiting for the host to poll the endpoint), the logging thread blocks, the
ring buffer fills, and the next LOG_DBG blocks the system workqueue.

This would explain:
- Why the freeze happens at random points after `zmk_endpoint_send_report`
  (it's wherever the log buffer happens to fill up)
- Why the freeze sometimes truncates mid-line (log thread stalls mid-write)
- Why longer sessions eventually freeze (log buffer pressure accumulates)
- Why combo-related code appeared in crash context (combo DBG logging is verbose)

## Confirmed: Hang, not fault (2026-04-09)

Left frozen keyboard connected with USB for several minutes after freeze.
Observations:
- MCU stayed enumerated on USB (`lsusb` showed device)
- No self-recovery — hung indefinitely until manual power cycle
- RESETREAS=0x00000000 after replug (cold boot, as expected from power loss)
- Last log line truncated mid-write inside `split_central_notify_func`
- ~11 hours uptime before freeze

**Conclusion: The freeze is a deadlock/infinite-wait, not a hard fault.**
The CPU is alive but the firmware is stuck — likely a thread blocked on a
kernel primitive (log buffer full → LOG_DBG blocks → system workqueue stalls).

## CDC ACM buffer increase — no effect (2026-04-10)

Increased `USB_CDC_ACM_RINGBUF_SIZE` to 4096 and enabled `LOG_MODE_OVERFLOW=y`.
Freeze occurred after ~1h11m, log truncated mid-write (`zmk_endpoint_` cut off).
MCU still enumerated on USB, same hang pattern. Buffer size is not the cause.

## BT-only test — freeze confirmed without logging (2026-04-13)

Flashed clean `dactyl_right.uf2` (no USB logging snippet, no CDC ACM, no logging
thread) and ran on battery for ~3 days. **Keyboard still froze.**

**This definitively rules out the logging system as the cause.** The freeze is
in the core ZMK firmware — BLE stack, event processing, or Zephyr kernel. All
log truncation observed in previous captures was the logging system being a
victim of the hang, not the cause.

## Summary of what's been ruled out

| Hypothesis | Test | Result |
|---|---|---|
| Stack overflow | Doubled all stacks | Still froze (but less often) |
| LONG_MAX sentinel mismatch | Fixed in fork | Still froze |
| Combo re-entrancy | CONFIG_ASSERT=y | No assertion fired |
| Combo system bug | DIAG instrumentation | Combo code completes cleanly |
| Battery GATT handle leak | Disabled battery fetching | Still froze |
| Log buffer blocking | Increased CDC buffer + overflow mode | Still froze |
| Logging system entirely | Clean BT-only firmware, no logging | **Still froze** |

## What we know

1. **It's a hang, not a fault** — MCU stays alive (USB enumerated) but firmware
   is stuck indefinitely. No self-recovery.
2. **Larger stacks reduce frequency** — reverting to defaults caused 3x more
   freezes, suggesting stack pressure is a contributing factor.
3. **Always during typing** — never during idle. Involves key event processing
   on the system workqueue.
4. **Peripheral (left half) events often involved** — most freezes occur during
   or just after processing a BLE notification from the peripheral.
5. **Position 31 (space/mod_tap) frequently involved** — peripheral key with
   hold-tap behavior appears in many crash contexts.
6. **Related upstream issues**: PR #3110 (system workqueue deadlock in split
   BLE), #2904 (peripheral causes central hang), #3100/#3262 (combo+holdtap
   crashes).

## Likely root cause: BLE TX buffer exhaustion → K_FOREVER deadlock

### Discovery (2026-04-13)

Zephyr's `bt_gatt_notify_cb` chooses its blocking behavior based on the calling
thread:
- System workqueue → `K_NO_WAIT` (returns error immediately)
- Any other thread → **`K_FOREVER`** (blocks until a buffer is free)

ZMK's `send_keyboard_report_callback` in hog.c calls `bt_gatt_notify_cb` from
`hog_work_q` — a **dedicated workqueue, not the system workqueue**. This means
it gets `K_FOREVER`.

The TX buffer pool is sized by `CONFIG_BT_ATT_TX_COUNT` (defaults to
`CONFIG_BT_BUF_ACL_TX_COUNT`, default **3**). With only 3 buffers:

1. Rapid typing generates HID reports faster than BLE can acknowledge them
2. All 3 TX buffers are in-flight waiting for host ACK
3. `bt_gatt_notify_cb` blocks `hog_work_q` with `K_FOREVER`
4. `zmk_hog_keyboard_msgq` fills (20 entries)
5. System workqueue calls `zmk_hog_send_keyboard_report` → `k_msgq_put` with
   `K_MSEC(100)` → times out → pops oldest → retries (but queue stays full
   because consumer is blocked)
6. System workqueue is now spending all its time in retry loops
7. BLE RX thread queues peripheral events → `k_work_submit` to system workqueue
   → events pile up because workqueue is busy retrying
8. Everything stalls

### Why it manifests as a hang, not a fault

No memory corruption, no stack overflow, no illegal instruction. Every thread
is alive but waiting:
- `hog_work_q`: blocked in `bt_gatt_notify_cb` → `K_FOREVER` on TX buffer
- System workqueue: stuck in `k_msgq_put` retry loop or starved by above
- BLE RX: can still queue events but nobody processes them

### Why larger stacks reduce frequency

Larger stacks don't fix the deadlock, but they provide more headroom for the
retry loop in `zmk_hog_send_keyboard_report` (recursive call at line 346) and
for deeper event processing call chains that happen while the system is under
TX buffer pressure.

### Relevant Zephyr issues

- **#53455**: Deadlock sending GATT notification from system workqueue (FIXED
  in v4.1 — system workqueue now uses K_NO_WAIT)
- **#78761**: ATT deadlock via system workqueue blocking BT RX thread (FIXED,
  adds CONFIG_BT_CONN_TX_NOTIFY_WQ)
- **#89705**: bt_gatt_notify from preemptible thread causes assert (FIXED)

### Applied fixes

1. **Increased BLE TX buffers**: `CONFIG_BT_BUF_ACL_TX_COUNT=12`,
   `CONFIG_BT_L2CAP_TX_BUF_COUNT=14`, `CONFIG_BT_CONN_TX_MAX=12`.
   Provides 4x more TX headroom before `K_FOREVER` kicks in.

2. **Hardware watchdog**: Task WDT fed from system workqueue every 5s, timeout
   30s. If the workqueue stalls, MCU auto-resets. RESETREAS will show WATCHDOG.

## Confirmed: hog_work_q deadlock, NOT system workqueue (2026-04-14)

With task watchdog monitoring the system workqueue (30s timeout):
- Keyboard froze with stuck key pattern
- **Watchdog did NOT fire** → system workqueue is alive and feeding it
- Stuck key held for 2-3 seconds then released → `hog_work_q` eventually
  got a TX buffer, sent the release report, then blocked again permanently
- No further input after the release → `hog_work_q` deadlocked in
  `bt_gatt_notify_cb` with `K_FOREVER`
- MCU stayed enumerated on USB, log output frozen
- 12 TX buffers (up from 3) were not enough to prevent the deadlock

**This definitively confirms the freeze is `hog_work_q` blocked in
`bt_gatt_notify_cb(K_FOREVER)` waiting for BLE TX buffers that the host
is not acknowledging fast enough.**

The system workqueue is not involved in the deadlock — it continues running
normally. The keyboard appears frozen because the HOG thread can't send HID
reports to the host.

### The fix

The real fix is to prevent `bt_gatt_notify_cb` from blocking forever on
`hog_work_q`. Options:

1. **Move HOG notifications to the system workqueue** — Zephyr uses `K_NO_WAIT`
   for the system workqueue, so notifications would fail immediately instead of
   blocking. ZMK would need to handle the `-ENOMEM` return and retry later.

2. **`CONFIG_BT_CONN_TX_NOTIFY_WQ=y`** — experimental Zephyr option that moves
   TX completion processing to a separate workqueue, which may help the TX
   buffer pool drain faster.

3. **Patch `hog.c` to check buffer availability** before calling
   `bt_gatt_notify_cb`, or use a timeout-based retry instead of blocking.

4. **Add a watchdog channel on `hog_work_q`** — since the system workqueue
   watchdog can't detect the HOG deadlock, add a second watchdog channel fed
   from `hog_work_q`. When HOG blocks, the watchdog fires and resets the MCU.

### Immediate mitigation

Option 4 (HOG watchdog) is the quickest path to auto-recovery. Option 1 or 3
is the proper fix that should be submitted upstream to ZMK.

## 12 TX buffers did not fix the freeze (2026-04-14)

Increased BT_BUF_ACL_TX_COUNT to 12 (4x default). Freeze occurred after ~1.5h.
Log truncated mid-write inside `peripheral_event_work_callback: Trigger ke` on
the system workqueue.

This contradicts the earlier freeze where the watchdog (monitoring system wq)
did NOT fire - suggesting the system workqueue was alive. Possible explanations:

1. **The hang is in different threads at different times** - sometimes hog_work_q,
   sometimes system workqueue, depending on exact timing
2. **The log truncation is misleading** - the USB CDC ACM backend may stop
   flushing when any thread blocks, and the last partial message in the buffer
   could be from any thread regardless of which one is actually hung
3. **The root cause is deeper in the Zephyr BLE stack** - a BLE controller or
   softdevice issue that affects all threads using BLE primitives

## Current status

The freeze remains unsolved. What we know for certain:
- It's a hang, not a fault (MCU stays alive on USB)
- It happens on BT-only (no USB logging) and with USB logging
- Larger stacks reduce frequency but don't eliminate it
- 12 TX buffers don't prevent it
- The combo system is not involved
- Battery level fetching is not the sole cause
- The logging system is not the cause
- The system workqueue watchdog sometimes fires, sometimes doesn't

## CONFIG_BT_CONN_TX_NOTIFY_WQ did not fix the freeze (2026-04-15)

Enabled separate TX completion workqueue. Freeze after ~24h uptime. Last line
`zmk_endpoint_send_report: usage page 0x07` - clean end, no truncation.

This rules out TX completion competing with system workqueue as the cause.

## Complete list of ruled-out hypotheses

| Hypothesis | Test | Result |
|---|---|---|
| Stack overflow | Doubled all stacks | Reduces frequency, doesn't eliminate |
| LONG_MAX sentinel mismatch | Fixed in fork | No effect |
| Combo re-entrancy | CONFIG_ASSERT=y | No assertion fired |
| Combo system bug | DIAG instrumentation | Combo code completes cleanly |
| Battery GATT handle leak | Disabled fetching | No effect |
| Log buffer blocking | Overflow mode + 4KB CDC buffer | No effect |
| Logging system | Clean BT-only firmware | Still froze |
| BLE TX buffer exhaustion | 12 buffers (4x default) | No effect |
| TX completion workqueue | CONFIG_BT_CONN_TX_NOTIFY_WQ=y | No effect |

## Remaining leads

- **File upstream issue** on zmkfirmware/zmk with full analysis
- **Reproduce in BabbleSim** - simulate the exact freeze conditions
- **Try ZMK stable release** instead of main to check for regression
- **Try different host** - test with a different BLE host (phone, different
  computer) to rule out host-side BLE stack issues
- **Zephyr BLE controller bug** - the nRF52840 BLE controller (softdevice
  equivalent in Zephyr) may have known issues with connection parameter
  handling or flow control under load
