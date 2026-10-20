# universal_ble 2.2.0 (patched)

Copy of universal_ble 2.2.0 from pub.dev (BSD 3-Clause, see LICENSE), used
through `dependency_overrides` in the app's `pubspec.yaml`. Only the example,
tests and hardware-in-the-loop folders were left out.

One change, in `windows/src/universal_ble_plugin.cpp`, `Pair()`: Windows 11
always uses `CustomPairAsync` (auto-accepts "Just Works" pairing) instead of
the system `PairAsync` dialog, whose "Allow" button stays disabled for the
Polar Verity Sense.

To drop the patch, remove the override and this folder.
