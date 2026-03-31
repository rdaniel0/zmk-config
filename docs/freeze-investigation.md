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
(combo.c:486). Two bugs identified:

### Bug 1: LONG_MAX vs LLONG_MAX type mismatch

`first_candidate_timeout()` (line 206) returns `LONG_MAX` as its "no timeout"
sentinel. `update_timeout_task()` (line 411) checks `if (first_timeout == LLONG_MAX)`.

On 32-bit ARM (nRF52840): `LONG_MAX` = 2^31-1, `LLONG_MAX` = 2^63-1. These are
**never equal**, so the cancel path is never taken. Instead, `k_work_schedule` is
called with `K_MSEC(LONG_MAX - k_uptime_get())` — a huge far-future timer. After
~25 days of uptime this goes negative.

This bug is wasteful (schedules a spurious timer) but may not directly cause the
crash at shorter uptimes.

### Bug 2: Re-entrant combo state modification (likely crash cause)

The `combo_timeout_handler` flow is:

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
  → update_timeout_task()  (reads stale/corrupted state)
```

When `cleanup()` → `release_pressed_keys()` re-raises captured position events,
those events are dispatched **synchronously** through the event manager back into
the combo listener. If a re-raised event triggers `position_state_down`, it
modifies the same global state (`pressed_keys[]`, `candidates[]`,
`timeout_task_timeout_at`) that `combo_timeout_handler` is in the middle of using.

When control returns to `combo_timeout_handler` line 486, the state it relies on
has been modified out from under it by the re-entrant call. `update_timeout_task`
may then:
- Read stale `pressed_keys[0].data.timestamp` values
- Compute a negative timeout
- Schedule a work item with undefined delay
- Trigger a Zephyr kernel fault

This explains why the freeze:
- Always involves combos (the re-entrancy is combo-specific)
- Sometimes involves peripheral events (they contribute captured keys that
  get re-raised)
- Sometimes truncates the log mid-line (hard fault) vs clean end (infinite
  reschedule loop)

### Related ZMK issues

- **zmkfirmware/zmk#3100**: Sticky shift + combo → hold-tap → macro crash (open)
- **zmkfirmware/zmk#3262**: Dongle crash traced to commit `9e36ebd` (open)
- **zmkfirmware/zmk#1944/#1945**: Previous combo timeout fix (closed)
- No existing issue reports the LONG_MAX/LLONG_MAX mismatch

## Next Steps

- **Fix LONG_MAX → LLONG_MAX** in `first_candidate_timeout()` (lines 206, 209)
- **Add defensive delay check** in `update_timeout_task()` to guard against
  negative timeouts
- **File upstream issue** on zmkfirmware/zmk with this analysis
- **Enable `CONFIG_ASSERT=y`** to catch the `pressed_keys_count > 0` assertion
  in `filter_timed_out_candidates` — if the re-entrancy theory is correct, this
  assertion may fire and give us a stack trace
- **Consider `CONFIG_RETAINED_MEM`** to capture fault info across resets
- **Reduce stack sizes back** to defaults since overflow is ruled out
