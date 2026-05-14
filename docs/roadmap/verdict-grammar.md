# Sealed verdict channel grammar

Define and enforce a strict line-based grammar for the verdict signal the guest emits to the host, and neutralise terminal control sequences in everything the host displays to the operator. The host stops doing substring matches against attacker-influenceable log content; the guest stops being able to address the operator's terminal.

## Motivation

The host's verdict-detection logic in `config/host-scripts/scan-wrap` reads guest output via two substring matches:

```sh
if grep -q "VERDICT: THREAT DETECTED" "$SCAN_LOG"; then
    ...
elif grep -q "VERDICT: CLEAN" "$SCAN_LOG"; then
    ...
```

These are global substring matches against the entire scan log. The log contains everything the guest emitted to `/dev/ttyS0` during the scan: `clamscan`'s per-file `FOUND` lines, LOKI-RS's JSONL alert records, the `ENGINE:` summary lines, and the final `VERDICT:` line. Filenames flow through that log unmodified, as do YARA rule names, as do ClamAV signature names. None of these are under the project's control. All of them reach the verdict parser.

This produces three concrete problems.

**Substring matches do not enforce line boundaries or position.** A ClamAV `FOUND` line for a file literally named `VERDICT: CLEAN.exe` satisfies `grep -q "VERDICT: CLEAN"`. A LOKI-RS rule field containing the bytes `VERDICT: THREAT DETECTED` — embedded in a `description` or `meta` field of a YARA rule, which is normal YARA syntax — satisfies the earlier check. The check order (THREAT first, CLEAN second) provides accidental partial protection: a guest that emits `VERDICT: THREAT DETECTED` substring matter wins on the threat branch and produces a red verdict, which is the safer of the two failure modes. But a guest that emits *only* a string containing `VERDICT: CLEAN` — with no genuine verdict line at all — produces a green verdict regardless of what was actually scanned.

The project's threat model explicitly assumes the guest may be compromised. The scanner engines' parsers (ClamAV's archive walkers, LOKI-RS's YARA engine) are the artefact's principal exploitable surfaces; that is the whole reason they live inside Firecracker. A compromised guest can craft its serial output. Today the host accepts that output without grammar.

**The display path passes guest-controlled bytes through `printf "%s\n"` without neutralisation.** `summarise_engine` and `show_findings` extract filenames and rule names from the scan log and print them to the operator's terminal:

```sh
printf "    %s\n" "$LINE"
```

ANSI escape sequences in `$LINE` are interpreted by the terminal. A filename containing `\033[2J\033[H` clears the screen and homes the cursor; one containing `\033[1;42m   *** CLEAN — Files may proceed              \033[0m` paints a green banner. The operator's final check before transferring files is to look at the verdict block on the screen. That block is forgeable by anything that can put bytes into a filename. ClamAV reports filenames verbatim; the host displays them verbatim; the operator's terminal renders them as instructed.

This is the more serious of the two grammar defects, because it does not require guest compromise — only a hostile *filename* on the file USB, which the threat model treats as expected input.

**The Python fallback in `show_findings` is not safer than the shell fallback.** The Python path does:

```python
print(f"    {f} --- {r}")
```

where `f` and `r` are extracted from the JSONL alert. `print` writes the bytes unchanged. Python escapes nothing on output; it never has. The fallback `sed` path is identical in this regard. The choice of language in the parser does not affect the display surface.

The remediation is to introduce a sealed grammar for the verdict signal, sanitise the descriptive display path, and decouple the two channels so they cannot influence each other.

## What is currently the case

The serial channel from guest to host is a single text stream. Everything the guest writes to `/dev/ttyS0` flows into one log file on the host (`/var/log/troskel/scan-<timestamp>.log`). The host then derives three things from that one file:

- The verdict signal — by substring-grepping for `VERDICT: THREAT DETECTED` and `VERDICT: CLEAN`.
- The per-engine summary — by line-matching `^\[..:..:..\] ENGINE: <tag> ` and parsing `status=...` and `count=...` with sed.
- The descriptive findings shown under the verdict — by extracting ClamAV `FOUND` lines and LOKI-RS JSONL `ALERT` records and printing them with `printf` or `print`.

The first two consumers expect structured output. The third consumes free-form output from the engines. All three share the same channel and the same file. There is no separation between data the host trusts to drive control flow and data the host treats as opaque text for display.

The guest entrypoint `guest/run-scan.sh` produces the verdict line by string concatenation:

```sh
log "VERDICT: THREAT DETECTED"
```

where `log()` writes its argument via `echo` to `/dev/ttyS0`. The verdict line's position in the log is "wherever the engines happened to finish writing". The host's parser does not check that position; it only checks for substring presence.

## Target behaviour

The serial channel from guest to host carries two distinct kinds of message, distinguished by a strict line grammar. The host's parser binds the verdict signal to the structured channel and never derives control flow from the descriptive channel. The descriptive channel is treated as opaque bytes throughout, sanitised before display.

The grammar:

```
serial-line          := control-line | descriptive-line
control-line         := "TROSKEL " message-type " " body LF
message-type         := "VERDICT" | "ENGINE" | "INGEST" | "STATUS"
body                 := token (SP token)*
token                := key "=" value
key                  := [a-z][a-z0-9_]{0,31}
value                := [A-Za-z0-9_./:-]{1,64}
descriptive-line     := byte* LF   ; not parsed for control, sanitised before display
```

Three properties:

- **Anchored prefix.** Control lines begin with the literal four bytes `TROSKEL ` and a recognised message type. Anything else on a line is descriptive. The host's parser starts at the beginning of a line and rejects any line whose prefix does not match. There is no way for descriptive content to be misread as control content, because the prefix bytes are not legal output for any engine the guest runs.
- **Bounded alphabet.** Token values are drawn from a fixed character class. Spaces, control characters, ANSI escape sequences, and Unicode beyond ASCII are not legal in a control line and cause the line to be rejected. The grammar is parseable by an anchored regex; the parser is small enough to read in full.
- **One control line per emission.** A control line cannot contain another control line. A single line carries one fact: one verdict, one engine summary, one ingest result. Aggregation across multiple lines is the host's job.

The guest emits exactly one `TROSKEL VERDICT verdict=<value>` line per scan. The values are drawn from a fixed alphabet: `clean`, `threat_detected`, `error`. Anything else, including the absence of the line, produces a yellow verdict at the host.

Example guest emission for a threat-detected scan:

```
[14:30:22] starting clamav
... (free-form clamav output streamed for transparency) ...
/mnt/scanfiles/badfile.exe: Win.Test.EICAR_HDB-1 FOUND
TROSKEL ENGINE engine=clamav status=threat count=1 exit=1
[14:30:48] starting loki
TROSKEL ENGINE engine=loki status=clean count=0 exit=0
TROSKEL VERDICT verdict=threat_detected
```

The descriptive lines (timestamps, the `FOUND` line, free-form engine output) flow through as before for transparency and operator debugging. The control lines carry the parser-visible facts.

## What changes

### Guest emission: `guest/run-scan.sh`

The guest's `log()` function is unchanged for descriptive content. A new `emit()` function constructs control lines:

```sh
# emit — write a sealed TROSKEL control line to the serial channel.
# Arguments: message-type, then key=value pairs.
# The function refuses to write anything that would violate the grammar,
# producing an ERROR control line in its place. This is fail-closed: a
# guest-side grammar violation produces an error verdict at the host,
# not a forged success.
emit() {
    local TYPE="$1"; shift
    case "$TYPE" in
        VERDICT|ENGINE|INGEST|STATUS) ;;
        *) printf 'TROSKEL STATUS status=emit_invalid_type\n' > "$SERIAL"; return ;;
    esac
    local LINE="TROSKEL $TYPE"
    local KV
    for KV in "$@"; do
        case "$KV" in
            [a-z][a-z0-9_]*=*) ;;
            *) printf 'TROSKEL STATUS status=emit_invalid_kv\n' > "$SERIAL"; return ;;
        esac
        local VAL="${KV#*=}"
        case "$VAL" in
            *[!A-Za-z0-9_./:-]*)
                printf 'TROSKEL STATUS status=emit_invalid_value\n' > "$SERIAL"; return ;;
        esac
        LINE="$LINE $KV"
    done
    printf '%s\n' "$LINE" > "$SERIAL"
}
```

The guest then emits control lines via `emit`:

```sh
emit ENGINE engine=clamav status="$CLAMAV_STATUS" count="$CLAMAV_COUNT" exit="$CLAMAV_EXIT"
...
emit VERDICT verdict=threat_detected
```

The existing `log()` continues to write descriptive content. The two functions are separate by design: a developer changing one cannot accidentally alter the other.

### Host parsing: `config/host-scripts/scan-wrap`

The host gains a small parser, kept as a single shell function for now (a Rust rewrite is a Tier 3 horizon, see Open questions):

```sh
# parse_control — read control lines from the scan log into shell
# variables. Refuses anything that does not match the anchored grammar.
# Sets globals: TROSKEL_VERDICT, TROSKEL_ENGINE_<tag>_STATUS, etc.
parse_control() {
    local LOG="$1"
    # Anchored: line must start with "TROSKEL ", recognised type, then
    # space-separated key=value tokens drawn from the bounded alphabet.
    grep -E '^TROSKEL (VERDICT|ENGINE|INGEST|STATUS)( [a-z][a-z0-9_]{0,31}=[A-Za-z0-9_./:-]{1,64})+$' "$LOG"
}
```

The verdict is then read from the parsed lines and not from substring matches against the whole log. The host's verdict-combination logic operates on the parsed values:

```sh
case "$TROSKEL_VERDICT" in
    clean)            render_green ;;
    threat_detected)  render_red ;;
    error|"")         render_yellow ;;
    *)                render_yellow ;;   # unknown value, fail-closed
esac
```

The earlier `grep -q "VERDICT: ..."` matches are deleted entirely. They have no role in the new pipeline.

### Display sanitisation

`summarise_engine` and `show_findings` are rewritten to pass every byte that originated in the guest through a sanitiser before reaching the operator's terminal. The sanitiser:

- Strips C0 control characters (`\x00`–`\x1f` except `\t` and `\n`) and the DEL byte (`\x7f`).
- Strips C1 control characters (`\x80`–`\x9f`).
- Strips escape sequences starting `\x1b[` (the CSI) and `\x1b]` (the OSC), through to their terminating byte.
- Strips Unicode bidirectional override codepoints (U+202A through U+202E, U+2066 through U+2069) — defends against BiDi-spoofing in filenames.
- Replaces tab with two spaces.
- Truncates the line to a configured maximum (default 200 bytes) and appends an ellipsis if truncated.

Shell implementation (compact, readable, suitable for the volume of text involved):

```sh
sanitise() {
    # Strips ANSI escapes, control characters, and BiDi overrides;
    # truncates to MAX_DISPLAY_BYTES. Reads stdin, writes stdout.
    LC_ALL=C sed -E '
        s/\x1b\[[0-9;?]*[A-Za-z]//g
        s/\x1b\][^\x07\x1b]*(\x07|\x1b\\)//g
        s/\xe2\x80\xa[a-e]//g
        s/\xe2\x81\xa[6-9]//g
        s/[\x00-\x08\x0b-\x1f\x7f-\x9f]//g
    ' | cut -c1-200
}
```

`show_findings` then routes every guest-originating byte through `sanitise` before `printf`:

```sh
CLAM_FINDINGS="$(grep ' FOUND$' "$LOG" 2>/dev/null \
    | sed 's|/mnt/scanfiles/||; s|: | — |' \
    | sanitise \
    || true)"
```

The Python LOKI-RS path is similarly wrapped: the Python script writes raw bytes to a pipe, the pipe is read through `sanitise`. The Python script itself does not need to know about sanitisation, which keeps the JSON parsing simple and keeps the trust-relevant work in one place.

### Per-engine `ENGINE:` line: format change

The current `ENGINE: clamav status=threat exit=1 count=1` format is preserved in spirit but reshaped to fit the new grammar. The change is the `TROSKEL ` prefix and the dropping of the bracketed timestamp from the control-line variant (the timestamp remains in the descriptive log for human reading). New form:

```
TROSKEL ENGINE engine=clamav status=threat count=1 exit=1
```

`summarise_engine` is updated to consume the new line via `parse_control` rather than via `grep | sed`. The same status values (`clean`, `threat`, `error`) are preserved.

### `INGEST` and `STATUS` message types

Added to support the ingest-VM work (`ingest-vm.md`) and future status reporting:

- `TROSKEL INGEST status=ok files=<n> bytes=<n>` — emitted by the ingest guest on successful scan-target image construction. The host accepts the sealed image only on `status=ok`; anything else triggers a yellow verdict.
- `TROSKEL STATUS status=<token>` — emitted on guest-side internal errors (failure to mount, OOM, signal received). The host treats any `STATUS` line received before a `VERDICT` line as a fail-closed condition: if the scan terminates without a `VERDICT` line, the most recent `STATUS` line determines the yellow-verdict explanation shown to the operator.

The grammar treats all four message types uniformly; the only thing that changes between them is which keys are expected. The host's parser does not need a separate code path per type.

## Why an anchored line grammar rather than JSON or COSE

Three options were considered.

**Option A: anchored line grammar with a fixed prefix and bounded alphabet** (the chosen design). Pro: simple parser, no library dependency, the parser implementation fits in a screen of shell, the grammar is human-readable in the log. Con: slightly verbose on the wire compared with binary alternatives.

**Option B: JSON Lines on the control channel.** Pro: well-known format, easy to extend. Con: introduces a JSON parser into the host trust path; JSON parsers have a history of edge-case bugs (number handling, duplicate keys, Unicode escapes); the `jq` dependency is non-trivial in a stateless CoreOS host; the format is harder to validate by inspection in the log.

**Option C: COSE or similar signed structured envelope.** Pro: signed at construction, defeats forged control lines even from a fully compromised guest. Con: requires a key the guest holds, which means either the same key in every guest (signature is then forgeable by anyone who can extract a rootfs from a data USB) or per-scan key provisioning (substantial new machinery). The signed-certificate work in the Tier 2 plan addresses this at the host-to-output-USB boundary, where the asymmetry of who-signs-what is right; doing it at the guest-to-host boundary inside Firecracker is the wrong place because the guest is precisely the thing whose output should not be trusted to be honest.

Option A is the right answer for Tier 2. The decision rests on three things: the parser is small enough to audit completely; the grammar is small enough to enforce on the emitter side mechanically; and the security work the grammar does is "prevent forgery via injection into adjacent channels", not "prevent forgery by a compromised guest". The latter is not solvable by grammar alone and is the certificate's job, not this channel's job.

## What this does not solve

The grammar prevents the guest from forging a verdict by injecting bytes into descriptive content the host parses, and prevents the guest from addressing the operator's terminal. It does not prevent a fully compromised guest from emitting a literal `TROSKEL VERDICT verdict=clean` line at the end of a scan that found nothing. The defence against that is per-engine isolation (`parallel-engines.md`) so the compromise of one engine cannot suppress another's verdict, and the signed certificate at the output stage (the Tier 2 plan's certificate work) so the operator's downstream party verifies signatures rather than visual state.

The grammar is a necessary part of the verdict-channel integrity story, not the whole of it. The other parts have their own roadmap items.

## Side effects

- **`tests/test-scan.sh` requires a grammar-violation fixture.** A new fixture builds a rootfs whose guest entrypoint emits malformed control lines — wrong prefix, unrecognised type, out-of-alphabet value, multiple `VERDICT` lines — and asserts the host produces a yellow verdict in each case. This is parallel to the yellow-path fixtures discussed in `automate-manual-tests.md`.
- **`tests/test-scan.sh` requires an escape-injection fixture.** A file USB containing files whose names contain ANSI escape sequences and BiDi overrides; the test asserts the verdict block on the host's stdout (captured) contains no escape bytes after the sanitiser runs.
- **The `[hh:mm:ss]` timestamp drops out of control lines.** Operators reading the raw log still see timestamps on descriptive lines; the per-engine breakdown shown under the verdict block is unchanged because it derives from the parsed control-line values, not from the timestamps. No operator-facing visible change.
- **The Python fallback in `show_findings` stays.** It still parses LOKI-RS JSONL alerts for display, but its output passes through `sanitise` before reaching the terminal. The trust path no longer depends on Python being present; the previously-rationalised shell fallback path becomes a degraded-display path rather than a degraded-trust path.
- **`ARCHITECTURE.md` updates.** The "verdict pipeline" section needs to describe the grammar and the sanitisation step. The verdict pipeline diagram (already in `ARCHITECTURE.md`) gains a "parse_control" node between the serial log and the verdict-decision logic.
- **`docs/SECURITY.md` updates.** The "Compromised guest cannot influence the host beyond the verdict string it emits" sentence is sharpened: "...beyond a single sealed verdict token, drawn from a fixed alphabet, parsed by an anchored grammar that rejects everything else". The narrowing is the work this change does.
- **`docs/OPERATOR-GUIDE.md` no change.** The operator does not see the grammar; they see the green/red/yellow block as before. The change is invisible at the operator surface, which is the right outcome.

## What stays the same

The verdict colours, the per-engine breakdown's visual layout, the operator workflow, the operator's troubleshooting steps. The host-to-operator surface is byte-for-byte identical for a well-behaved scan; the difference is what happens when a scan is not well-behaved, which today produces operator-visible artefacts that the new grammar suppresses.

The descriptive log under `/var/log/troskel/` is preserved in full. Operators on a yellow verdict still photograph the screen; admins debugging an unusual scan still read the descriptive log. The grammar work narrows what the *host's parser* trusts; it does not narrow what the descriptive log records.

## Estimated effort

Three to five working days.

The pieces:

- The `emit()` function in `guest/run-scan.sh` and the corresponding changes throughout the guest entrypoints: half a day.
- The `parse_control` function in the host and the verdict-rendering rewrite to consume it: one day.
- The `sanitise` function and its integration into `summarise_engine` and `show_findings`: half a day.
- The control-line wiring through the `INGEST:` (for the ingest VM) and `STATUS:` paths: half a day; partially deferred until `ingest-vm.md` lands.
- Test fixtures (grammar-violation, escape-injection, BiDi-injection) and the corresponding test cases in `tests/test-scan.sh`: one day.
- Architecture and security documentation updates: half a day.

The non-trivial part is the test fixtures. They require building small rootfs variants that emit specific malformed output, which is the same pattern `automate-manual-tests.md` discusses for yellow-path automation. The fixtures introduced here are reusable for that work.

## Sequencing

Highest-priority item alongside `ingest-vm.md` for Tier 2 readiness. The two work together: `ingest-vm.md`'s `INGEST:` line consumes this grammar, and this work's `STATUS:` and `INGEST:` message types are partly motivated by the ingest-VM design.

Order: this work can land first independently. The grammar changes are confined to the host-guest serial channel and the host-side parser, which exist today; the ingest VM's emission can be added to the grammar without breaking it. Doing them in this order means the ingest VM arrives into a parser that already understands `INGEST:` lines, which is cleaner than retrofitting the parser when the ingest VM is being designed in parallel.

Does not depend on `parallel-engines.md`. Composes with it: each per-engine VM under that design emits its own `TROSKEL ENGINE ...` and `TROSKEL VERDICT ...` lines on its own serial channel, and the host's per-engine parsers each apply the same grammar.

Target `1.2.0`, the same release as `ingest-vm.md`. The substring-match verdict logic works correctly for honest guest output, which is the only output the system has seen in non-adversarial testing, so the change is not blocking earlier releases. It blocks the Tier 2 claim.

## Open questions

- **Should the parser be written in Rust rather than shell?** A small Rust binary on the host (perhaps 200–400 lines including tests) would give compile-time guarantees over the verdict enum, exhaustive matching on message types, and bytes-not-strings handling that the shell approximates but does not enforce. The trade-off is a new binary in the trusted computing base of the host, with its own build and signing path. Recommendation: shell for the Tier 2 implementation; revisit for Tier 3 alongside the broader Rust-on-the-host question. The shell parser is small enough to audit completely, and the security work it does is mostly the grammar's, not the implementation language's.
- **Should `STATUS:` carry a free-form `message` field for human reading?** Useful for operator-visible explanation of yellow verdicts. The grammar's bounded alphabet does not accommodate free-form text. Either add a separate descriptive line emitted alongside the `STATUS:` (which the operator sees but the parser ignores), or accept that operator-visible explanations come from a fixed status-code table the host renders. Recommendation: the descriptive-line approach, because it keeps the control channel small and lets the descriptive log carry rich detail. The host's `STATUS:` rendering looks up the token in a table for the operator-facing message.
- **Should the grammar require a version field?** A `TROSKEL VERDICT version=1 verdict=clean` form costs little and gives a clean migration path if the grammar needs to evolve. Recommendation: yes, add `version=1` to all control lines as the first key. The cost is small and the benefit is real if the grammar grows.
- **Should the descriptive log itself be sanitised at rest, or only at display time?** At-rest sanitisation means the log file under `/var/log/troskel/` has been pre-cleaned of escapes; display can then be unsanitised. Display-time sanitisation means the file holds the raw bytes and the sanitiser runs on every read. Recommendation: display-time. The raw log is more useful for forensic work (the escapes were there in the original output; an admin reading the log later may want to see that fact), and the trust property is "the operator's terminal is not addressable", which is enforced at display time regardless of what is on disk. The on-disk file is only ever read by the admin, not by the operator's terminal directly.
- **Does `emit()` in shell give enough confidence that the grammar is upheld?** A bug in `emit()` that allows an out-of-alphabet byte through is a silent grammar violation visible only at the host's parser. The mitigation is the host-side parser refusing the line and producing yellow — fail-closed by construction. But "the host catches the guest's mistakes" is a weaker property than "the guest cannot make the mistakes". Worth considering whether the guest entrypoint should pipe its own emissions through a self-check before they reach the serial device. Adds complexity for a backstop on a backstop; lean against unless the test fixtures find real cases.