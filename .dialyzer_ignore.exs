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
[
  # `ngettext/3` expands to a call into Gettext's generated plural dispatch,
  # which passes an opaque `Expo.PluralForms` struct positionally. Dialyzer
  # reports an opaqueness mismatch on that library-internal call; it is not a
  # defect in our code. Triggered by the first ngettext use (group member count).
  {"lib/eden_web/gettext.ex", :call_without_opaque}
]
