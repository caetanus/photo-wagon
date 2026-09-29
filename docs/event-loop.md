# Qt and vibe-core event-loop investigation

DSide supports running Qt and vibe-core on the same main thread. Photo Wagon
currently does not use that support. Its separate core thread is an application
design choice, not a consequence of QObject thread affinity.

## What is implemented

In the sibling `qt-dlang-gen` checkout:

- `runtime/eventcore/eventcore/drivers/posix/qt.d` defines `QtEventDriver`.
- `runtime/qtmoc/qtd_eventloop.cpp` connects descriptor readiness through
  `QSocketNotifier` and processes Qt events for eventcore's wait.
- `tests/vibe/vibeqt.d` exercises Qt timers, vibe timers, and TCP together.
- `tests/vibe/libp2pqt.d` exercises two libp2p hosts with a handshake, Identify,
  and Ping on the Qt driver.

The entry point is:

```d
// After creating QCoreApplication/QGuiApplication, before using vibe services:
setupEventDriver(new QtEventDriver);
// Start the application's owned tasks, then:
runEventLoop();
```

The eventcore dependency must use its `generic` configuration, and the build
must include DSide's driver source with `EventcoreQtDriver` enabled. The local
Qt Quick `libshims.a` already exports the four `qtd_ec_*` functions it needs.

Calling `QCoreApplication.exec()` alone does not drive vibe's scheduler with
this implementation. The driver queues readiness callbacks during Qt dispatch
and delivers them afterward, avoiding fiber resumption inside that dispatch.

## Verification on Linux

The existing DSide integration binaries were run locally. The timer/TCP test
was also rebuilt from the current driver source in an isolated directory.

| Check | Observed result |
| --- | --- |
| Qt timer + vibe timer + local TCP | `vibe ticks=3 qt ticks=4 tcp=[hello] in 60ms` |
| Two libp2p hosts using the Qt driver | `identified=true pinged=true rtt=157us` |
| Current driver plus `vibe.core.concurrency.async` | Worker abort: `setupEventDriver() was not called for this thread.` |

The last check added `async(() { return 42; }).getResult()` to the timer/TCP
test. With eventcore configured as `generic`, its driver is explicitly installed
per thread. Installing it on the main thread leaves the vibe worker threads
without a driver. The current vibe-core 2.14.0 worker startup does not install
one, so a direct configuration switch is insufficient for Photo Wagon's use
of `async`.

These checks establish that the shared loop works and identify a migration
blocker; they do not establish full Photo Wagon GUI compatibility or validate
Hyperswarm on this driver. The supplied driver is POSIX-specific; Windows needs
a separate integration decision.

## What Photo Wagon would need to change

1. Configure the desktop build for the Qt eventcore driver. Keep native drivers
   for standalone headless builds and arrange appropriate driver initialization
   for other runtime modes of the desktop binary.
2. Create the Qt application and install its driver before constructing the
   in-process link or any vibe service. The current link constructor already
   creates a shared vibe event.
3. Start the daemon on the main thread and replace the separate `CoreThread`
   and `QCoreApplication.exec()` lifecycle with the shared `runEventLoop()`.
   Preserve UI → link → core separation: sharing a thread does not require
   exposing core objects to QML or introducing Qt imports into core services.
4. Initialize a suitable native event driver on each background worker, or
   supply an equivalent worker integration. Image processing and hashing must
   continue to run off the UI thread; installing the Qt driver on every worker
   is not the intended solution.
5. Connect window closing, explicit Quit, daemon shutdown, startup failures,
   and signals to coordinated task shutdown and loop exit. Audit Qt deferred
   deletion and callback reentrancy under the new entry point.
6. Measure UI responsiveness during imports, SQLite queries, and image analysis.
   Synchronous core work that currently occupies the separate core thread
   would otherwise occupy the GUI thread.

The investigation leaves application runtime behavior unchanged. A migration
should be verified with the core tests, P2P integration tests, and a real QML
session covering import, analysis, requests, and clean shutdown.
