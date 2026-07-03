---
target: "#165 group management panel"
total_score: 29
p0_count: 0
p1_count: 0
timestamp: 2026-06-26T07-04-33Z
slug: group-management-panel-165
---
# Critique — #165 group management UI (conversation profile panel)

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Live everywhere (role flip, removal, rename → header/sidebar/panel, system notices); no success toast on rename, no loading state on add |
| 2 | Match System / Real World | 3 | owner/admin/member + "Add members"/"Remove from group"/"Transfer ownership" are familiar; the action icons are not self-evident |
| 3 | User Control and Freedom | 3 | Rename Cancel; modal X/Esc; data-confirm on destructive; owner-leave blocked with a clear flash; no Undo after remove (must re-add) |
| 4 | Consistency and Standards | 4 | Mirrors the channel members modal exactly (same icons, matrix, modal); role suffix matches |
| 5 | Error Prevention | 3 | Confirms + server validation + owner-leave guard; icon-only cluster invites misclicks (key=transfer next to remove) |
| 6 | Recognition Rather Than Recall | 2 | **Action cluster is icon-only** (shield/key/user-minus); meaning lives in hover tooltips — unavailable on touch |
| 7 | Flexibility and Efficiency | 3 | Quick per-row actions + multi-select add; no keyboard accelerators |
| 8 | Aesthetic and Minimalist | 3 | Clean, well-composed panel; three icons + role suffix per row add some density |
| 9 | Error Recovery | 3 | Plain-language flashes ("Couldn't remove that member", "Transfer ownership before leaving the group") |
| 10 | Help and Documentation | 2 | No inline hint for what the icons do beyond tooltips |
| **Total** | | **29/40** | **Good** |

## Anti-Patterns Verdict
- **LLM assessment:** Does NOT read as AI-generated. It reuses eden's committed design system + the Mattermost-corporate reference (the channel members modal pattern verbatim). No slop tells — no gradient text, no eyebrows, no identical card grids, no glassmorphism.
- **Deterministic scan:** detect.mjs on chat_live.ex → 8 `broken-image` warnings, ALL false positives (HEEx dynamic `<img src={…}>` the static scanner can't resolve) and **none in the #165 regions**. #165 markup is clean.

## What's working
1. **Consistency with the channel layer** — identical role matrix/icons/modal means a user who learned channel admin already knows group admin. The strongest thing here.
2. **Authority is honest end-to-end** — controls only appear for owner/admin (verified), the live system notices + header/sidebar rename keep everyone's view truthful, and the owner-leave guard prevents an ownerless group.
3. **Inline rename** is low-friction (pencil → input + Save/Cancel right where the name is, no modal detour).

## Priority Issues
- **[P2] Action cluster is icon-only.** shield/key/red-user-minus convey "make admin / transfer ownership / remove" only via hover tooltips. On touch there is no hover, so a mobile owner can't learn them; "key = transfer ownership" is not guessable. This is also the root of your own report ("no clear kick button"). → A Telegram-style context menu on the member row (right-click / long-press → text items "Make admin", "Remove from group", "Transfer ownership…") would carry labels, work on touch, and reuse eden's existing `.ContextMenu` hook. *(/impeccable clarify or a small craft)*
- **[P3] The "· owner" role treatment is weak** (you called it "кривая"). A muted-tinted chip/badge would read as a label rather than trailing text. *(/impeccable typeset / layout)*
- **[P3] Add-members modal lists names without @handle.** With near-duplicate display names (e.g. "Matthew" vs "Матвей") there's nothing to disambiguate by. → Show `@handle` under each name (the panel roster already does). *(/impeccable clarify)*
- **[P3] No success confirmation on rename.** The form just closes; a brief "Group renamed" flash (you already flash on failure) closes the loop. *(/impeccable clarify)*

## Persona Red Flags
- **Jordan (first-timer):** the icon-only cluster — no labels; won't know "key = transfer ownership"; on mobile can't even hover to find out.
- **Casey (mobile):** full-screen panel is fine, but the micro-icon action buttons risk <44px touch targets, and the no-hover-on-touch hides their meaning entirely.
- **Sam (a11y):** buttons carry `aria-label` (good) and role is conveyed by text not color-alone (good); verify the `ed-btn--icon` focus ring is visible on keyboard tab through the cluster.

## Minor Observations
- "Add (N)" button correctly reflects selection count — good feedback.
- Rename input is `maxlength=100` matching the server changeset — good alignment.

## Questions to Consider
- Should member management be a per-row **context menu** (text labels, touch-friendly) rather than an always-visible icon cluster — matching how eden already handles message actions?
- Is the owner/admin distinction worth a visible chip, or is the trailing "· owner" enough once it's styled?
