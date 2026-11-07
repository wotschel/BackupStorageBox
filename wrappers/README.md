# Local backup actions

Put executable scripts in `pre/` and `post/`. Call `backup.sh` as usual;
it runs each directory in ascending C-locale filename order. Use names such
as `10-stop-myapp.sh`, `20-dump-database.sh` and `10-start-myapp.sh`.

Non-executable files are skipped with a warning and a `chmod +x` hint.

Pre failures skip the backup; all post scripts still run after preparation
starts, including on errors and HUP/INT/TERM. Post scripts must handle partial
preparation. Dry runs and administrative commands skip both phases.

Scripts run as separate processes, not via Bash `source`. They receive
`BACKUP_CONFIG`, `BACKUP_NAME`, and `BACKUP_EXIT_CODE` in their environment.
Use absolute paths. See the main README for configuration and examples.

Git ignores local actions, retaining only this guide and directory placeholders.
They survive normal pulls but need their own backup; `git clean -fdx` removes
them. Protect these directories and scripts from untrusted writers.
