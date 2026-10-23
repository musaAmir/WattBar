# Energy history

Open **Energy & Apps…** from either WattBar menu, or reopen WattBar, to explore the past minute, hour, or rolling 24 hours. The compact menu also shows all three periods.

- **Average draw (W)** is the time-weighted average over recorded time.
- **Energy recorded (Wh / mWh / kWh)** is power integrated over that time. For example, 30 W recorded for one hour is 30 Wh.
- **Recorded coverage** tells you how much of the selected period was measured. Missing data, sleep, time while WattBar was closed, and time before the first pair of readings contribute neither energy nor coverage. A partially recorded day is not projected into a full day.
- The system and battery sensors are tracked separately. Battery transfer includes both charging and discharging; it is not equivalent to whole-Mac electricity consumption. These are Mac sensor estimates rather than outlet measurements; external peripherals and charger losses may not be included.

Readings are integrated using trapezoids between consecutive valid samples. Long acquisition gaps and sleep interrupt the integration anchor. Whole-Mac history is compacted into ten-second buckets with exact coverage spans. A partially selected bucket uses the span's average, so a boundary's energy/peak may be approximate by up to ten seconds. The chart leaves gaps when no measurement exists.

## Apps and processes

On supported Macs, WattBar reads the public `proc_pid_rusage` CPU-energy counters and displays **CPU energy** per app/process. These are CPU-only counters, not a division of the whole-Mac sensor total. Display, GPU, network and other device power are outside this attribution. CPU time is shown on systems/periods without energy counters. It is not converted into estimated watts.

WattBar samples accessible processes about every five seconds, or at the configured sensor refresh rate when it is slower. Nested helpers are grouped under their outer application. Processes without an application bundle are named by executable. Only processes visible in two consecutive snapshots contribute deltas: very short-lived, exited-between-samples or inaccessible processes may be missed. PID reuse and counter resets never import lifetime consumption. CPU percentages average over the observed interval and can exceed 100% for multiple cores.

Per-app history retains the latest two minutes as individual intervals, then compacts to minute buckets. Older boundary attribution is proportional to observed time in that minute. Up to 100 identities are retained per bucket; additional resources are included under **Other processes**. Closed apps remain in the selected historical window. A dash indicates incomplete or unsupported CPU-energy measurement.

## Storage

History is stored locally in `~/Library/Application Support/WattBar/energy-history.json` and `app-activity.json`. Only the last 24 hours are retained. Checkpoints are atomic and normally written once per minute, with a final save on sleep or normal quit. A crash can lose the latest unsaved minute. Neither file is uploaded. Corrupt or unwritable history surfaces a notice in the interface; new readings continue in memory. Integration baselines are rebuilt on every launch.

## Apple references

- [XNU Recount documentation](https://github.com/apple-oss-distributions/xnu/blob/main/doc/observability/recount.md) describes per-thread/process CPU accounting and CPU-energy counters.
- [XNU task resource accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c) supplies CPU time in Mach time units and energy in nanojoules.
- [Activity Monitor energy consumption guide](https://support.apple.com/guide/activity-monitor/view-energy-consumption-actmntr43697/mac) explains Apple's separate relative Energy Impact metric. WattBar's CPU energy values are not that score.
