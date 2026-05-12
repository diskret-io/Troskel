# Test fixtures

Small binary fixtures used by the test suite. Each is committed in base64-
encoded form so that developer AV scanners do not flag the repo itself.
The test scripts decode them to disk at run time before feeding them to
the scanner.

## `EICAR.b64`

Base64-encoded EICAR test string. Decodes to the standard 68-byte EICAR
file. Both ClamAV and LOKI-RS (via YARA Forge Core's `TRELLIX_ARC_Malw_Eicar`
rule) detect this. Used by `test-scan.sh` to exercise both engines' red
verdict paths.

Regenerate:
```bash
printf 'X5O!P%%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*\n' \
    | base64 > tests/files/EICAR.b64
```

## `encrypted-test.zip.b64`

Base64-encoded password-protected ZIP archive. Decodes to a small encrypted
ZIP containing one benign text file, encrypted with the password
`troskel-test`. The encrypted content is detected by ClamAV's
`--alert-encrypted-archive` flag (introduced in the clamav-tightening work).
Used by `test-scan.sh` to confirm that flag is engaged.

The ZIP itself contains nothing malicious — the value is structural, not
content. ClamAV flags it because the scanner cannot inspect its contents,
not because of what's inside.

Regenerate:
```bash
mkdir -p /tmp/encgen && cd /tmp/encgen
echo "this is benign test content for ClamAV --alert-encrypted-archive" \
    > content.txt
zip -e -P troskel-test encrypted-test.zip content.txt
base64 < encrypted-test.zip > "$REPO_ROOT/tests/files/encrypted-test.zip.b64"
cd - && rm -rf /tmp/encgen
```

The `zip -e -P` form bakes the password into the archive non-interactively.
Bump the password by editing this recipe and `test-scan.sh`'s assertion if
needed — neither value is sensitive (the file is a test fixture, not real
encryption).

Requires `zip` on the host running the regeneration. `zip` is not on
`prepare-build-machine.sh`'s install list because it is only used here —
install separately on the rare occasion this fixture needs to be rebuilt.