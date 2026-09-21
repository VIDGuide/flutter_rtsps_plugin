## Unreleased

* Expose `RtspStreamController.maxConcurrentStreams` (currently 8) so callers stop
  hardcoding the native `RtspStreamManager.maxStreams` limit.
* Add a Dart test that reads the Swift source and fails if the Dart constant drifts
  from the native limit.

## 0.0.1

* TODO: Describe initial release.
