defmodule EdenWeb.Notifier do
  @moduledoc """
  The notification renderer host (#215 sound / #217 desktop), extracted from ChatLive
  so it can render on **every** authenticated page (#272). An always-present, invisible
  `#notifier` element catches the server-gated `notify` push_event (delivered by
  `EdenWeb.NotifyHook`) and plays a chime / shows an OS notification per the viewer's
  toggles. The colocated hook travels with this component, so any LiveView that renders
  `<.notifier prefs={@notify_prefs} />` gets the behavior.
  """
  use Phoenix.Component

  attr :prefs, :map, required: true

  attr :focused_conv, :any,
    default: nil,
    doc:
      "The conversation this session is actively viewing (ChatLive only), so a background tab " <>
        "can suppress an OS banner for a chat another tab is already reading (#363/R165). nil " <>
        "everywhere else (Settings/Admin) — those tabs never claim focus."

  def notifier(assigns) do
    ~H"""
    <div
      id="notifier"
      phx-hook=".Notifier"
      data-sound={to_string(@prefs.sound)}
      data-sound-name={@prefs.sound_name}
      data-desktop={to_string(@prefs.desktop)}
      data-focused-conv={@focused_conv}
      hidden
    >
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Notifier">
      // #215: play a short chime when the server pushes a gated "notify" (the #213
      // recipient gating already ran — self / muted / DND / non-followers are gone, and
      // NotifyHook already dropped the focused-chat / muted-channel cases). Web Audio
      // can't start without a user gesture, so we lazily unlock the context on the first
      // interaction; a throttle keeps a burst of messages from machine-gunning the sound.
      // #217 adds the desktop-notification output to this same hook: when you're AWAY it shows
      // an OS notification (suppressing the chime, no double-ding); when you're ON the site it
      // plays the chime instead (no redundant OS banner). See onNotify for the split.
      export default {
        mounted() {
          // The AudioContext + throttle live on `window`, NOT the hook: switching between
          // the messenger and a channel is a `navigate` (remount), which would otherwise
          // re-create the hook with a fresh, locked context — the chime would go silent in
          // channel mode until the next click. Window-scoping keeps it unlocked across remounts.
          this.unlock = () => {
            if (!window.__edAudio) {
              const AC = window.AudioContext || window.webkitAudioContext
              if (AC) window.__edAudio = new AC()
            }
            if (window.__edAudio && window.__edAudio.state === "suspended") window.__edAudio.resume()
          }
          window.addEventListener("pointerdown", this.unlock)
          window.addEventListener("keydown", this.unlock)
          this.handleEvent("notify", (payload) => this.onNotify(payload))
          // #363/R165: publish which conversation this tab is actively reading so a background
          // tab can stay silent for a chat this one is already showing (server-side focus
          // suppression is per-session and can't see across tabs). Heartbeat on focus/visibility
          // changes and a slow interval; the reader in `otherTabViewing` treats it as fresh
          // for a few seconds.
          this.beatFocus()
          this.beat = () => this.beatFocus()
          window.addEventListener("focus", this.beat)
          window.addEventListener("blur", this.beat)
          document.addEventListener("visibilitychange", this.beat)
          this.focusTimer = setInterval(this.beat, 2000)
        },
        updated() {
          // The active conversation (data-focused-conv) can change without a remount (switching
          // chats is a patch), so re-publish on every render.
          this.beatFocus()
        },
        destroyed() {
          window.removeEventListener("pointerdown", this.unlock)
          window.removeEventListener("keydown", this.unlock)
          window.removeEventListener("focus", this.beat)
          window.removeEventListener("blur", this.beat)
          document.removeEventListener("visibilitychange", this.beat)
          if (this.focusTimer) clearInterval(this.focusTimer)
        },
        beatFocus() {
          // Only a tab that is BOTH focused and visible on a real conversation claims it. Stamped
          // with a timestamp so a stale claim (tab switched away, closed) ages out on its own.
          const conv = this.el.dataset.focusedConv
          if (!conv || document.hidden || !document.hasFocus()) return
          try {
            localStorage.setItem("ed:activeConv", JSON.stringify({ id: conv, ts: Date.now() }))
          } catch (_e) {}
        },
        otherTabViewing(convId) {
          // Is another (focused) tab currently reading this conversation? Fresh within 5s of the
          // last heartbeat (2s interval) — comfortably longer than the beat, short enough that a
          // closed/blurred tab stops suppressing quickly. localStorage throws in private mode →
          // treat as "no other tab" (show the banner, never go silent on an error).
          try {
            const raw = localStorage.getItem("ed:activeConv")
            if (!raw) return false
            const { id, ts } = JSON.parse(raw)
            return String(id) === String(convId) && Date.now() - ts < 5000
          } catch (_e) {
            return false
          }
        },
        supportsRenotify() {
          try {
            return "Notification" in window && "renotify" in Notification.prototype
          } catch (_e) {
            return false
          }
        },
        onNotify(payload) {
          // #217: split the output by where your attention is. The #213 server gate already
          // dropped the case where you're actively viewing THIS chat; here we split the rest:
          //   • on the site (window focused AND tab visible) → the in-app chime only — you're
          //     looking at eden, an OS banner would just be redundant noise.
          //   • away (another app/window, minimized, or a background tab) → the desktop OS
          //     notification (it carries its own system sound), so we suppress the chime to
          //     avoid a double-ding. Falls back to the chime when desktop is off or not
          //     permitted on this device (a per-user pref can outrun a per-device permission).
          const here = !document.hidden && document.hasFocus()
          if (here) {
            if (this.el.dataset.sound === "true") this.chime()
          } else {
            // #363/R165: if another tab is focused on this exact conversation, it's already being
            // read — don't banner or chime it from this background tab.
            if (this.otherTabViewing(payload.conversation_id)) return
            const desktopShown = this.el.dataset.desktop === "true" && this.notify(payload)
            // Suppress the chime only when the OS banner will actually RE-alert on each message —
            // i.e. the browser honors `renotify` (Chrome/Edge). Firefox/Safari ignore renotify, so
            // a repeat banner for the same conversation swaps silently; keeping the chime there
            // (#363/R166) means a burst of messages isn't reduced to one audible alert. A rare
            // double-signal beats going deaf on the team's main browser (Firefox).
            const suppressChime = desktopShown && this.supportsRenotify()
            if (this.el.dataset.sound === "true" && !suppressChime) this.chime()
          }
        },
        notify(payload) {
          if (!("Notification" in window) || Notification.permission !== "granted") return false
          // A room and a knock (#363/R029 — a join request into a room) both head with "#room";
          // a DM heads with the sender, a group with its title. The knock/room/group forms then
          // append the person ("#talk · Alice"), the DM shows the sender alone.
          const roomish = payload.kind === "room" || payload.kind === "knock"
          const head = roomish && payload.conv_title ? "#" + payload.conv_title : payload.conv_title
          const title =
            payload.kind === "dm"
              ? payload.sender_name || ""
              : [head, payload.sender_name].filter(Boolean).join(" · ")
          // tag collapses a conversation's banners to one; renotify re-alerts on each new
          // message (#273) so the 2nd..Nth message of a chat isn't a silent swap. Chrome/Edge
          // honor renotify; Firefox/Safari ignore it harmlessly.
          const opts = {
            body: payload.body || "",
            tag: "ed-conv-" + payload.conversation_id,
            renotify: true,
          }
          if (payload.avatar_url) opts.icon = payload.avatar_url // same-origin GET, sends the session cookie
          let n
          try { n = new Notification(title, opts) } catch (_e) { return false }
          // Click → focus the window and jump to the message (the permalink scrolls to it).
          n.onclick = () => {
            window.focus()
            const path = payload.channel_id
              ? "/channels/" + payload.channel_id + "/r/" + payload.conversation_id + "/m/" + payload.message_id
              : "/app/c/" + payload.conversation_id + "/m/" + payload.message_id
            n.close()
            window.location.assign(path)
          }
          return true
        },
        chime() {
          const ctx = window.__edAudio
          if (!ctx) return // never unlocked (no gesture this page session)
          const now = Date.now()
          // Throttle bursts AND dedup across tabs (#273): two background tabs shouldn't both
          // ring the same message. The last-chime timestamp lives in localStorage (shared per
          // origin), so the second tab within the window stays silent. Private-mode throws →
          // fall back to ringing (better a rare double than silence).
          let last = 0
          try { last = parseInt(localStorage.getItem("ed:lastChime") || "0", 10) || 0 } catch (_e) {}
          if (now - last < 1500) return
          try { localStorage.setItem("ed:lastChime", String(now)) } catch (_e) {}
          // The browser auto-suspends an AudioContext after a spell in the background; once a
          // gesture has unlocked it, resume() needs no fresh gesture, so a notification can still
          // ring while you're in another app. Play now if running, else after the resume settles.
          if (ctx.state === "running") this.play(ctx)
          else ctx.resume().then(() => ctx.state === "running" && this.play(ctx)).catch(() => {})
        },
        play(ctx) {
          // #289: the chime is the user's chosen preset (window.edSound owns the
          // synth + preset table, shared with the Settings preview). data-sound-name is
          // re-rendered live when the user changes the preset (#363/R096 — NotifyHook reassigns
          // notify_prefs on {:notify_prefs_changed}), so a fresh read here is current; an
          // unknown/absent name falls back to the default.
          window.edSound && window.edSound.play(ctx, this.el.dataset.soundName)
        },
      }
    </script>
    """
  end
end
