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

  def notifier(assigns) do
    ~H"""
    <div
      id="notifier"
      phx-hook=".Notifier"
      data-sound={to_string(@prefs.sound)}
      data-desktop={to_string(@prefs.desktop)}
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
        },
        destroyed() {
          window.removeEventListener("pointerdown", this.unlock)
          window.removeEventListener("keydown", this.unlock)
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
          // With several eden tabs open the OS de-dups banners by `tag` (one per conversation),
          // but a focused tab may chime while a background tab banners the same message — an
          // accepted minor; cross-tab election would be out of proportion to the annoyance.
          const here = !document.hidden && document.hasFocus()
          if (here) {
            if (this.el.dataset.sound === "true") this.chime()
          } else {
            const desktopShown = this.el.dataset.desktop === "true" && this.notify(payload)
            if (this.el.dataset.sound === "true" && !desktopShown) this.chime()
          }
        },
        notify(payload) {
          if (!("Notification" in window) || Notification.permission !== "granted") return false
          const head =
            payload.kind === "room" && payload.conv_title ? "#" + payload.conv_title : payload.conv_title
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
          const t = ctx.currentTime
          const gain = ctx.createGain()
          gain.connect(ctx.destination)
          // Soft attack/decay so it's a gentle chime, not a beep.
          gain.gain.setValueAtTime(0.0001, t)
          gain.gain.exponentialRampToValueAtTime(0.11, t + 0.012)
          gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.34)
          const osc = ctx.createOscillator()
          osc.type = "sine"
          osc.frequency.setValueAtTime(660, t)
          osc.frequency.setValueAtTime(880, t + 0.09) // a small two-note rise
          osc.connect(gain)
          osc.start(t)
          osc.stop(t + 0.35)
        },
      }
    </script>
    """
  end
end
