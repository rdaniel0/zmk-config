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

## Next Steps

- **Test with doubled stacks** (commit 1d17436) — if freezes stop, it was stack
  overflow. If they persist, rule it out.
- **Retained memory**: enable `CONFIG_RETAINED_MEM` to persist fault info across
  resets, since USB logging can't capture the fault handler output
- **Watchdog**: check if Zephyr's watchdog is resetting the MCU — the USB
  re-enumeration in the third freeze suggests a reset rather than a hang
- **BLE peripheral event path**: if stacks are ruled out, focus investigation
  on `split_central_notify_func` → `peripheral_event_work_callback` →
  `position_state_changed_listener` code path
