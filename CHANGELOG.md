## Unreleased

* Expose `RtspStreamController.maxConcurrentStreams` (currently 8) so callers stop
  hardcoding the native `RtspStreamManager.maxStreams` limit.
* Add a Dart test that reads the Swift source and fails if the Dart constant drifts
  from the native limit.
* Drop a torn-down session from the manager's stream-limit accounting even when it
  tears itself down (error or stall watchdog); previously an errored session kept a
  slot forever and later starts failed with `tooManyStreams`. A failed start now
  also releases the resources it had already created.
* Fix `disposeAll()` leaking every session on engine detach (it ran with a weak
  reference to an already-deallocated manager).
* Wire the previously dead `RtspTransport.onDisconnect` and add a 15s RTP-stall
  watchdog, so a half-open TCP stall recovers in seconds instead of waiting for the
  5-minute periodic reconnect.
* Rebuild reconnects by connecting the replacement pipeline before detaching the
  live one, and close the replacement on failure; a failed reconnect no longer
  freezes a healthy stream or leaks a connection, and can no longer resurrect a
  session that has been torn down.
* Require 2xx on DESCRIBE/SETUP/PLAY, and replay interleaved RTP frames seen during
  the handshake into the demuxer instead of discarding the opening frames.
* Add an awaiting-IDR gate to the decoder and make the jitter buffer act on its
  computed EMA, rebasing the playout clock immediately on a forward timestamp jump.

## 0.0.1

* TODO: Describe initial release.
