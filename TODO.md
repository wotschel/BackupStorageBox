# TODO

- [x] Improve logging: consistent severity levels, clear run summaries and
  useful diagnostics for pre/post actions; document log rotation.
- [x] Provide ready-to-install systemd service and timer unit files for
  periodic backups, with installation and configuration instructions.

Next steps, in priority order:

- [ ] Add an integration test with real restic and a temporary local repository:
  back up and restore test files, then verify contents, permissions and symlinks.
- [ ] Add `--check-config` to validate configuration, dependencies, file
  permissions and discovered pre/post actions without executing those actions.
- [ ] Add GitHub Actions for Bash syntax checks, ShellCheck and automated tests
  on pushes and pull requests.
- [ ] Provide a separate systemd service/timer for periodic `restic check`,
  optionally reading a subset of stored data.
