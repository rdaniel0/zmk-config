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

### Comparison with March 24 freeze

| | March 24 | March 30 |
|---|---|---|
| Uptime at freeze | 12:07:32 | 31:48:21 |
| Last function | `position_state_changed_listener` | `position_state_changed_listener` |
| Trigger | peripheral release after combo timeout | peripheral release after combo timeout |
| Stuck key | position 18 (local kscan) | position 2 (peripheral) |
| Preceding event | `combo_timeout_handler: ABOUT TO UPDATE` | `combo_timeout_handler: ABOUT TO UPDATE` |
| MPU fault logged | No | No |
| Log truncation | Clean line ending | Mid-line truncation |

The pattern is identical: **combo timeout fires, followed by a peripheral release
notification, and the MCU freezes in `position_state_changed_listener`**.

## Emerging Theory

The `combo_timeout_handler: ABOUT TO UPDATE IN TIMEOUT` message appears
immediately before both freezes. This is a delayed work item on the system
workqueue. The sequence suggests:

1. Combo timeout work item runs, processes the timeout
2. A peripheral BLE notification arrives (queued during combo processing)
3. The peripheral event work item starts processing
4. MCU dies during `position_state_changed_listener` for the peripheral release

The combo timeout handler's "ABOUT TO UPDATE" step may be corrupting state
that `position_state_changed_listener` subsequently reads, or the deep call
stack at this point (combo cleanup + peripheral event + listener dispatch)
may be overflowing the system workqueue stack despite the increase to 2560 bytes.

The mid-line log truncation in the March 30 capture strongly suggests a hard
fault or watchdog reset rather than an infinite loop — the CPU stopped executing
abruptly.

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

## Gaps / Next Steps

- **Thread analyzer data**: the March 30 session had `CONFIG_THREAD_ANALYZER`
  enabled — check the raw log for stack high watermarks before the freeze
- **Combo "ABOUT TO UPDATE" code path**: investigate what this does in the ZMK
  combo source — is it modifying global state that the next event reads?
- **Stack overflow hypothesis**: the system workqueue stack (2560 bytes) may not
  be enough when combo timeout + peripheral event processing overlap on the call
  stack. Try increasing to 4096.
- **Retained memory**: enable `CONFIG_RETAINED_MEM` to persist fault info across
  resets, since USB logging can't capture the fault handler output
- **Watchdog**: check if Zephyr's watchdog is resetting the MCU (would explain
  no fault output)
