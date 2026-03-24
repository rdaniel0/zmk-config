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

## Gaps / Next Steps

- No on-device log storage — all logging is USB-only, so crash context is lost
  if the USB buffer hasn't flushed
- Consider `CONFIG_RETAINED_MEM` or flash-based crash log to persist fault info
  across resets
- Consider `CONFIG_THREAD_ANALYZER` to measure actual stack usage at runtime
- Monitor whether the freeze always involves concurrent local + peripheral events
