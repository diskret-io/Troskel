# Tests

Test scripts run by `make test` (or its sub-targets `make test-build` and `make test-scan`). All tests run inside the `troskel-build` container.

See [`../docs/DEVELOPER.md`](../docs/DEVELOPER.md) for the test pipeline, tier breakdown, fixtures, and manual procedures.

Test fixtures (EICAR, encrypted ZIP) and their regeneration recipes are in [`files/README.md`](files/README.md). Manual scan procedures that cannot be automated cleanly are in [`manual-tests-scan.md`](manual-tests-scan.md).