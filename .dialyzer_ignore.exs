# Dialyzer warning suppressions (used via `dialyzer: [ignore_warnings: ...]` in mix.exs).
#
# Each entry may be one of:
#   - a string or regex matched against the warning's formatted line, or
#   - a {"path/file.ex", :warning_type} tuple, or
#   - a {"path/file.ex", :warning_type, line} tuple.
#
# Keep this list empty by default. Only suppress a warning that is a confirmed
# false positive, and add a comment explaining why. Prefer fixing the underlying
# type issue. Use `mix dialyzer --list-unused-filters` to prune stale entries.
[]
