---
target: "#165 group management panel"
total_score: 36
p0_count: 0
p1_count: 0
timestamp: 2026-06-26T08-34-04Z
slug: group-management-panel-165
---
# Critique (re-score after fixes) — #165 group management UI

## Design Health Score

| # | Heuristic | Was | Now | Change |
|---|-----------|-----|-----|--------|
| 1 | Visibility of System Status | 3 | 4 | rename now flashes "Group renamed."; everything else already live |
| 2 | Match System / Real World | 3 | 4 | role chip + labeled menu + @handle in the add modal |
| 3 | User Control and Freedom | 3 | 3 | (unchanged) cancel/esc/confirm; still no true undo after remove |
| 4 | Consistency and Standards | 4 | 4 | member ⋯ menu now matches the message ⋯ menu pattern |
| 5 | Error Prevention | 3 | 4 | labeled menu + separated danger item + data-confirm + server validation; no adjacent-icon misclicks |
| 6 | Recognition Rather Than Recall | 2 | 4 | actions are a labeled menu behind a discoverable ⋯ (was icon-only/hover-only) |
| 7 | Flexibility and Efficiency | 3 | 3 | (unchanged) no keyboard accelerators |
| 8 | Aesthetic and Minimalist | 3 | 4 | rows cleaner (one ⋯ vs three icons); role reads as a chip |
| 9 | Error Recovery | 3 | 3 | (unchanged) plain-language flashes |
| 10 | Help and Documentation | 2 | 3 | self-documenting menu labels + tooltips + state-explaining system notices |
| **Total** | | **29** | **36/40** | **Excellent** |

## What changed
- **Icon-only cluster → labeled context menu.** Per member row (owner/admin), a ⋯ trigger (also right-click / long-press) opens an `.ed-menu` with text items: "Make admin" / "Remove admin", "Transfer ownership", and a separated danger "Remove from group". Reuses the `.ContextMenu` hook so it positions `fixed` (the roster scrolls, an absolute menu would clip). Resolves the top P2 + the user's "no clear kick button" + the touch/recognition persona flags.
- **Role chip** replaces the "· owner" text suffix (muted pill; name truncates, chip stays).
- **@handle in the add-members picker** (both the group add + the people picker) disambiguates duplicate display names.
- **Rename success flash** ("Group renamed.") closes the feedback loop.
- (From the senior review + audit, already folded in: system notices excluded from the sidebar preview; rename input `aria-label` + focus-on-open; dead clause removed.)

## Remaining (deliberately not done)
- Control 3 / Flexibility 3 / Error-recovery 3 are inherent to a small chat panel (no undo-after-remove, no keyboard accelerators, generic failure flashes) — not worth complexity here.
