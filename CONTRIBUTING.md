# Contributing

## Git workflow

### Branches

`main` is the only long-lived branch. Work on anything non-trivial in a short-lived feature branch, then merge back via a pull request, even if you are the sole reviewer. This keeps the history readable and gives you a natural review checkpoint before code lands.

```bash
git checkout -b feat/parallel-engines
# do the work
git checkout main
git merge --no-ff feat/parallel-engines -m "feat: add parallel engine VM architecture"
git branch -d feat/parallel-engines
```

The `--no-ff` flag preserves a merge commit so the history shows that a body of related work landed together, rather than a flat stream of individual commits.

### Commit messages

Use a short type prefix. The full conventional commits spec is not enforced, but keeping the type consistent makes the log scannable.

```
feat: add capa as a third scan engine
fix: pass ext4 image directly to Firecracker, remove losetup
docs: update README admin workflow for troskel-build.sh
chore: rename SCANNER-DATA label to TROSKEL-DATA
refactor: extract guest scripts from build-scanner-image.sh heredocs
test: add POSIX sh compliance check to test-validate.sh
```

Useful types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`. Nothing else needed.

The subject line should complete the sentence "this commit will...". Keep it under 72 characters. If more context is needed, leave a blank line after the subject and write a body.

### Tags

Tag meaningful milestones — not every merge, but points worth being able to return to.

```bash
git tag -a v0.2.0 -m "feat: parallel engine VM architecture"
git push origin v0.2.0
```

Use `v0.x.y` until the project is stable enough to call `v1.0.0`. A tag is a checkpoint, not a formal release — it does not need release notes at this stage.

### Before committing

Run `make validate` first. It catches Butane config errors, shellcheck failures, and guest script bashisms in under 30 seconds. If it passes, the commit is unlikely to break CI.

```bash
make validate
git add .
git diff --staged --stat   # review what is actually staged
git commit
```

The `git diff --staged --stat` step is worth making a habit, it is the last chance to catch an accidentally staged file before it enters the history.

### What not to commit

The `.gitignore` covers the main cases. As an extra reminder:

- `config/eff-large-wordlist.txt` — downloaded at setup time, not stored in the repo
- Any real `ignition.json` — compiled output, regenerated from source
- Build artefacts under `/var/lib/troskel/`
- Scan logs under `/var/log/troskel/`
- Any file containing a real password hash, key, or credential