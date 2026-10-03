# Local test runner

```bash
tests/runner/run.sh                 # everything, maximum safe parallelism
tests/runner/run.sh --serial        # one test at a time (reference / debugging)
tests/runner/run.sh --lanes backend # or: static, frontend, syntax, shell
tests/runner/run.sh nft_apply 'autotune_*'
tests/runner/run.sh --repeat 5      # flake hunting under load
```

From Windows PowerShell: `.\tests\runner\run.ps1` with the same arguments
(runs inside WSL). Logs of the last run: `~/.cache/forkop-tests/last`.

## Lanes

All lanes run at the same time:

| Lane     | What                                              | Parallelism           |
|----------|---------------------------------------------------|-----------------------|
| backend  | `tests/*.sh`                                      | job pool, longest first |
| syntax   | `ucode -c`, `ucode -S -c` for `usr/lib/**/*.uc`   | `xargs -P nproc`      |
| shell    | `shellcheck --severity=error` (CI file set)       | `xargs -P nproc`      |
| frontend | prettier `--check`, eslint, vitest, `tsc --noEmit`| 4 tools at once       |

The frontend lane is read-only: the CI build step is skipped because it
rewrites the committed LuCI bundle. Under WSL it uses Windows `node.exe` when
`node_modules` were installed from Windows.

## Parallelism

The backend suite waits far more than it computes: sequentially it keeps
about 2% of the machine busy, because production code has fixed grace
periods (`sleep 1`, integer drain/quiet timeouts) and tests stub daemons.
With the longest tests scheduled first, wall time equals the longest single
test (an autotune test, 2-3 min): on 16 CPUs every worker count from 4 to
64 gave the same wall time, larger counts only used more memory. The default
is one worker per CPU (`nproc`); override with `-j N` or `FORKOP_TEST_JOBS`.

## Isolation

Each backend test runs in its own user, mount, pid and network namespace:

- private tmpfs `/tmp` and `$HOME` - fixed `/tmp/...` paths cannot collide;
- own pid namespace - leftover background processes are killed with the test,
  and `ps`/`pgrep` see only the test's processes;
- network namespace with loopback only - no test can reach the host network
  or the router;
- no capabilities - real `nft`, `ip`, `sysctl` fail instead of changing the
  host, and file permissions behave as for a normal user.

Without user namespaces the runner falls back to a private `TMPDIR` per test.

The backend and static lanes run on a fresh copy of the working tree on the
Linux filesystem (`/mnt/c` is slow and serialises parallel access); use
`--in-place` to run from the working tree itself. Stored timings only change
the scheduling order, never the result.

Router tests in `tests/router/` are not run: they need a real device.
