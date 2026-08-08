// Optimistic text sends + an in-memory outbound queue. A send is rendered
// immediately, queued, and (re)sent over the socket; while the socket is
// down it waits and flushes on reconnect, so a flaky cross-border link
// doesn't lose or duplicate messages (the server dedups by client_id).
// Photo sends fall through to the normal LiveView path (they need a live
// upload). In-memory only: a full page reload clears the queue.
export default {
  mounted() {
    this.connected = true
    this.convId = this.el.dataset.conversationId
    // Tapping Send must NOT collapse the keyboard (#439, TG behavior): a button tap
    // steals focus from the input → blur → keyboard drops. Desktop: preventDefault on
    // mousedown keeps focus while the click still submits. Touch: preventDefault on
    // touchend suppresses BOTH the focus steal and the synthesized click, so we submit
    // the form ourselves — one submission, input keeps focus, keyboard stays up.
    const sendBtn = this.el.querySelector('button[type="submit"]')
    if (sendBtn) {
      sendBtn.addEventListener("mousedown", (e) => e.preventDefault())
      sendBtn.addEventListener("touchend", (e) => {
        e.preventDefault()
        this.el.requestSubmit()
      })
    }
    // Edit (#164): the server pre-fills (start) / clears (cancel|save) the chat input
    // directly — setting value= via render fights LiveView's controlled input.
    this.handleEvent("set_composer_body", ({ body }) => {
      const input = this.el.querySelector('input[name="message[body]"]')
      if (!input) return
      input.value = body
      input.dispatchEvent(new Event("input", { bubbles: true }))
      if (body) {
        input.focus()
        try { input.setSelectionRange(body.length, body.length) } catch (_e) {}
      }
    })
    this.queue = []
    // Tracks the compose-overlay open transition (used by the #164 text→media caption
    // seed in updated()).
    this.prevComposeOpen = !!this.el.querySelector("[data-upload-preview]")
    // Per-send delivery watchdogs by client_id (#142): a clock shows while a
    // send awaits ack; if none arrives in time the clock flips to a red ●!.
    // ~20s when online (covers several LiveView reconnects on a flaky link);
    // a window "offline" event shortens any pending wait to ~3s.
    this.sendTimers = new Map()
    this.onOffline = () => this.onWentOffline()
    window.addEventListener("offline", this.onOffline)
    // True while a media send is in flight — gates the overlay re-hide (#130).
    this.sending = false
    // Object URLs for staged video previews (#117), keyed
    // "name:size:lastModified" and shared with the .VideoPreview hook via
    // this element. Revoked when a
    // clip is removed (VideoPreview destroyed) or the conversation switches.
    this.el.edenVideoUrls = new Map()
    // The original picked File objects, keyed "name:size:lastModified", so a failed
    // upload can be RE-SENT (#…): the LiveView entry's File is gone after a cancel, so
    // we stash it at pick. Kept until the composer is torn down (destroyed).
    this.el.edenFiles = new Map()
    this.input = this.el.querySelector('input[name="message[body]"]')
    this.pending = document.getElementById("pending-messages")
    this.scroller = document.getElementById("message-scroll")
    // Group ids we've asked the server to hold open (a failed card is parked in #pending for
    // them) — so maybeReleaseGroup only releases a group we actually held, not every send.
    this.heldGroups = new Set()
    // Expose this instance so the thread composer (.ThreadSendQueue, a separate colocated
    // hook that can't share these methods) can route a thread album/file send through the
    // SAME sequential feeder (phase F trim): one item at a time (no batch stall), each
    // landing as a thread reply progressively. Only the DM/room pane owns the feeder.
    window.__edSendQueue = this
    // Resume any send whose upload was cut off by a reload (phase E): rebuild its optimistic
    // rows from the durable store and re-feed the unfinished items. Fire-and-forget (async).
    this.resumeSends()
    // Re-fuse a merged file group's optimistic rows when a twin swaps out (fired by the
    // riser after it removes a completed twin), so the in-flight bubble stays one bubble.
    this._onRegroup = (e) => {
      const gid = e.detail && e.detail.groupId
      this.reGroupOptimistic(gid)
      // A twin swapped out — if that emptied a HELD group's #pending nodes (its failed card
      // was resent and just landed), let the server close the tail again.
      this.maybeReleaseGroup(gid)
    }
    window.addEventListener("ed:regroup", this._onRegroup)
    this.el.addEventListener("submit", (e) => this.onSubmit(e))
    // "Send as file" (#122): a type="button" so it's never the implicit Enter
    // submitter. On click, flag the next submit as uncompressed-document and
    // requestSubmit() through the normal media path (onSubmit reads the flag).
    this._asFile = false
    this.el.addEventListener("click", (e) => {
      if (!e.target.closest("[data-send-as-file]")) return
      this._asFile = true
      this.el.requestSubmit()
    })
    // Observe file picks (in capture) for two reasons: the #119 upload queue
    // (hold a batch picked while another uploads) and the video-preview URLs.
    // Photos are NO LONGER shrunk client-side — the server compresses every
    // photo for storage (#122), and "Send as file" (#122) needs the untouched
    // original — so a normal pick just stages natively (no intercept/re-encode).
    this.onPick = (e) => {
      const input = e.target
      const isFile = input instanceof HTMLInputElement && input.type === "file"
      // The dedicated Resend / sequential feeds target :attachment_retry / :attachment_seq
      // directly — they must NOT be gated/queued like a normal :attachment pick (that would
      // divert them into the main config). Let them propagate untouched (clones already stashed).
      if (isFile && (input.name === "attachment_retry" || input.name === "attachment_seq")) return
      // Capture video object URLs for previews wherever the batch ends up.
      this.captureVideoUrls(e)
      // A pick larger than the config accepts at once (max_staged_entries, #193) would
      // tag the excess :too_many_files — a CONFIG-level error that blocks the WHOLE
      // upload (nothing stages, the ring freezes, the 30s watchdog then drops the node).
      // The server splits a pick into albums, but only up to what STAGES; past the cap
      // we stop the native stage and tell the user, instead of wedging silently.
      if (isFile && input.files?.length > this.maxStaged()) {
        e.stopImmediatePropagation()
        e.preventDefault()
        input.value = ""
        this.pushEvent("media_too_many", { max: this.maxStaged() })
        return
      }
      // A pick while another send uploads is fine now (the sequential engine feeds
      // :attachment_seq, so a fresh pick just stages into the staging-only :attachment tray
      // and opens the compose overlay as usual — TG-style, no "in queue" gating). Clear the
      // send-in-flight guard so the preview overlay shows again (#130); the event propagates
      // so LiveView stages the file natively.
      if (isFile) this.sending = false
    }
    this.el.addEventListener("input", this.onPick, true)
    this.el.addEventListener("change", this.onPick, true)
    // A media send the server REJECTED (validation / decompression-bomb / storage): leave
    // the optimistic node in the retriable FAILED state (red !, Resend from the stashed
    // Files + Delete) — the same affordance as the stall watchdog — instead of silently
    // removing it, which read as a lost send (#361/R082, matching commit_album's comment).
    // If the node is already gone (swapped/removed), there's nothing to fail.
    this.handleEvent("media_failed", ({ id }) => {
      const node = this.findNode(id)
      if (node) this.markUploadFailed(node)
    })
    // Settle a failed-card Resend (#…): the server sends it, then names the card's
    // client_id here — ok (the client_id swap already removed the card) vs failed.
    this.handleEvent("retry_done", (payload) => this.onRetryDone(payload))
    // Determinate upload progress for an in-flight send. The server addresses
    // the album's averaged ring by its client_id (#95) and each file's ring by
    // its upload ref (#149); we drive whichever node it names and re-arm that
    // node's stall watchdog.
    this.handleEvent("media_progress", ({ id, ref, percent }) => {
      const node = ref
        ? this.pending?.querySelector(`[data-upload-ref="${ref}"]`)
        : this.findNode(id)
      this.setRing(node, percent)
      this.armStall(node && node.closest(".ed-msg, .ed-flat"))
    })
    // Sequential-send progress (TG-attachments): the server drives ONE node at a time by
    // its client_id — a file card, or an album node (its ring aggregates the album's
    // photos). Same ring + stall-watchdog re-arm as media_progress.
    this.handleEvent("seq_progress", ({ id, percent }) => {
      // A media photo drives its own TILE (data-item-cid); a file its card row (data-client-id).
      const node =
        this.findTile(id) || this.findNode(id)
      this.setRing(node, percent)
      // Re-arm the CURRENT item's watchdog (seq-aware: fails only this item/photo, fires seq_reset).
      this.armSeqStall(node)
    })
    // One sequential item finished uploading (its real message/album streamed in and
    // swapped its optimistic node) — feed the next item in the queue.
    this.handleEvent("seq_done", ({ id }) => this.onSeqDone(id))
  },
  disconnected() {
    this.connected = false
    // Freeze every in-flight upload's stall watchdog: a dropped link is NOT a stall —
    // LiveView pauses the upload and resumes it on reconnect — so the clock must not run
    // while offline, else a flaky/slow connection loses files after the timeout (the
    // "even on slow internet the file vanishes ~30s later" bug). Re-armed on reconnect.
    if (this.pending) {
      for (const row of this.pending.children) {
        if (row._stall) { clearTimeout(row._stall); row._stall = null }
      }
    }
  },
  destroyed() {
    // Composer torn down (e.g. live_redirect out of chat without a
    // conversation switch): per-tile VideoPreview.destroyed revokes live
    // previews, this sweeps any object URL left without a tile (a rejected
    // or never-rendered entry) so it can't outlive the page (#117).
    if (this.el.edenVideoUrls) {
      for (const url of this.el.edenVideoUrls.values()) URL.revokeObjectURL(url)
      this.el.edenVideoUrls.clear()
    }
    this.el.edenFiles?.clear()
    if (window.__edSendQueue === this) delete window.__edSendQueue
    window.removeEventListener("offline", this.onOffline)
    if (this._onRegroup) window.removeEventListener("ed:regroup", this._onRegroup)
    this.sendTimers.forEach((t) => clearTimeout(t))
    this.sendTimers.clear()
    // The nodeless (thread) stall watchdog lives on the hook, not in sendTimers — clear it
    // too so it can't fire pumpSeq/pushEvent on a torn-down hook.
    if (this._seqStall) clearTimeout(this._seqStall)
    this.closeFailMenu()
  },
  reconnected() {
    this.connected = true
    // Re-arm anything that was in-flight when the link dropped; the
    // server dedups by client_id, so re-sending can't duplicate.
    for (const item of this.queue) item.sent = false
    this.flush()
    // Re-arm the stall watchdog for in-flight upload nodes (frozen on disconnect):
    // LiveView resumes the paused upload now, so the clock restarts from a clean 0.
    if (this.pending) {
      // Retry nodes keep their own dedicated channel + watchdog — re-arm them as before.
      for (const row of this.pending.children) {
        if (row.dataset.retry === "true" &&
            !row.classList.contains("ed-msg-failed") &&
            row.querySelector(".ed-media-sending__ring-fill")) {
          this.armStall(row)
        }
      }
      // Sequential send: only the ONE in-flight item was uploading — re-arm just its node
      // (queued items stay unarmed until their turn), so the watchdog restarts cleanly and,
      // if the resumed upload is truly wedged, skips to the next after the timeout.
      if (this.seqFeeding) {
        const it = this.seqFeeding
        const node = this.pending.querySelector(`[data-client-id="${it.albumCid || it.clientId}"]`)
        this.armSeqStall(node && node.closest(".ed-msg, .ed-flat"))
      }
      // The server re-mounted on reconnect (fresh process → held_groups reset), but a failed
      // card may still be parked in #pending. Re-establish each group's seam hold so the
      // fused bubble doesn't spring open (its tail closing above the dangling card) after a
      // reconnect. Re-derived from the DOM, so heldGroups can't drift out of sync either.
      const reheld = new Set()
      for (const row of this.pending.children) {
        const gid = row.dataset.groupId
        if (gid && row.querySelector(".ed-file--failed, .ed-msg-failed")) reheld.add(gid)
      }
      reheld.forEach((gid) => {
        this.heldGroups.add(gid)
        this.reGroupOptimistic(gid)
        this.pushEvent("group_hold", { group_id: gid })
      })
    }
  },
  updated() {
    // Switched conversation: reset the text send queue/timers, and hide (not wipe)
    // this chat's in-flight media nodes so background-upload progress survives (#144).
    if (this.el.dataset.conversationId !== this.convId) {
      this.convId = this.el.dataset.conversationId
      this.queue = []
      this.sending = false
      this.sendTimers.forEach((t) => clearTimeout(t))
      this.sendTimers.clear()
      this.closeFailMenu()
      // #144: a media send keeps uploading after you leave its chat, so don't wipe
      // its optimistic node — only the text twins (untagged; their delivery is
      // queue/timer-bound to this chat, as before). Media/file nodes carry their
      // owning conversation (data-conv-id): hide other chats', re-show this chat's.
      // On re-show, dedup against the just-reset stream — if the real row already
      // arrived while we were away, drop the twin so node + real row never double up.
      if (this.pending) {
        // The main composer's stream is #messages (paired with this.pending =
        // #pending-messages, set in mounted()); the thread composer is a separate
        // hook with its own containers, so this pairing is fixed here.
        const stream = document.getElementById("messages")
        for (const node of [...this.pending.children]) {
          const conv = node.dataset.convId
          if (!conv) {
            node.remove()
          } else if (conv !== this.convId) {
            node.style.display = "none"
          } else if (
            node.dataset.clientId &&
            stream?.querySelector(`[data-client-id="${node.dataset.clientId}"]`)
          ) {
            node.remove()
          } else {
            node.style.display = ""
          }
        }
      }
      // Revoke staged-clip object URLs from the old conversation (#117) — but NOT
      // while a media send is in flight: its entries (and their previews) survive the
      // switch (#144), so revoking here would blank the tiles if its overlay ever
      // reopens. Cleared normally on a switch with nothing in flight, and on destroy.
      if (this.el.dataset.sendingMedia !== "true") {
        for (const url of this.el.edenVideoUrls.values()) URL.revokeObjectURL(url)
        this.el.edenVideoUrls.clear()
      }
    }
    // A media send is in flight (#130): re-hide the preview overlay on every
    // patch so a re-render beating media_sending — or morphdom restoring the
    // server markup over the JS display:none — can't flash it back. Runs in
    // the patch cycle before paint, so the flash never reaches the screen.
    // Cleared on a fresh pick (onPick) so the next staging shows normally.
    if (this.sending) {
      const ov = this.el.querySelector("[data-upload-preview]")
      if (ov) ov.style.display = "none"
    }
    const composeOpen = !!this.el.querySelector("[data-upload-preview]")
    // #164 text→media: when the overlay OPENS during a text edit, seed its caption with
    // the edit text (in #composer-body) so the conversion's caption defaults to the
    // message text — editable + blankable there. On the open transition only, so later
    // patches never clobber the user's caption edits.
    if (composeOpen && !this.prevComposeOpen && this.el.querySelector("[data-edit-active]")) {
      const cap = this.el.querySelector("[data-compose-caption]")
      if (cap && !cap.value && this.input) cap.value = this.input.value
    }
    this.prevComposeOpen = composeOpen
  },
  onSubmit(e) {
    // #122: "Send as file" sets this flag (then requestSubmit()s) — read + reset it
    // unconditionally so an aborted/error submit can't leak it into the next send.
    const asFile = this._asFile === true
    this._asFile = false
    // Media (#95 redesign): mint a client_id, render the local-preview node
    // (tagged with it) + a progress ring, push it fire-and-forget on
    // media_sending (which also closes the overlay), and let the live upload
    // proceed UNTOUCHED — no preventDefault, no gating. The id rides the
    // socket BEFORE the native submit's "send" (same channel → FIFO order),
    // so the server stamps the real message and the existing data-client-id
    // swap drops this exact twin. The OLD two-pass instead held the submit
    // until a pushEvent ack re-fired it; that ack path was the fragile bit
    // that stalled real uploads in prod (the spinner-forever bug).
    const overlay = this.el.querySelector("[data-upload-preview]")
    // #164 text→media: editing a text message + attached media → convert. Unlike a
    // normal media send, an edit updates an EXISTING row (via {:message_edited}), so
    // draw NO optimistic node and push NO media_sending — just close the overlay and
    // let the native submit upload the :attachment entries + fire "send" (the server
    // routes editing+media to edit_message_media). Keep a client-side error visible.
    if (overlay && this.el.querySelector("[data-edit-active]")) {
      if (overlay.querySelector(".ed-attach-err")) {
        e.preventDefault()
        return
      }
      overlay.querySelectorAll("video").forEach((v) => {
        try { v.pause() } catch (_e) {}
      })
      this.sending = true
      overlay.style.display = "none"
      window.dispatchEvent(new CustomEvent("ed:after-send"))
      return
    }
    if (overlay) {
      // A staged entry with a client-side error (e.g. a video over the size
      // cap) won't upload. Don't close the overlay (media_sending) — that
      // would hide the error — and don't fake an optimistic node; keep the
      // error visible so the send isn't a silent no-op (#112: "при отправке
      // видео ничего не происходит" was an oversized clip whose error the
      // overlay-close swallowed).
      if (overlay.querySelector(".ed-attach-err")) {
        e.preventDefault()
        return
      }
      // Capture the caption NOW, while the overlay is still open: it rides the
      // media_sending push (so it can't be lost if the upload is slow) and is
      // drawn in the optimistic node (so it shows during upload, not only on the
      // real row's arrival).
      const caption = (this.el.querySelector("[data-compose-caption]")?.value || "").trim()
      // Media tiles (image/video) are split into albums of maxAlbum (#193): the server
      // splits a big pick into a sequence of albums, so split the optimistic the SAME
      // way NOW — one node per batch, each with its own client_id — so every album
      // appears and uploads on send (Telegram-style), not the overflow popping in
      // already-loaded after the first. Files post one message PER file (#149).
      const mediaTiles = [...overlay.querySelectorAll(".ed-compose__tile")]
      const hasMedia = mediaTiles.length > 0
      // #122: a photos-only "Send as file" lands as document cards — draw the
      // optimistic the same way so a slow upload doesn't show an album that reshapes.
      // A mixed batch (a video present) keeps the album node (video renders inline).
      const asFileDocs = asFile && !overlay.querySelector(".ed-compose__video")
      // Build the SEQUENTIAL upload queue (TG-attachments): album photos first (in album
      // order), then files. Each item is fed one at a time on :attachment_seq so it gets
      // the full link (no concurrent per-chunk-timeout starvation → no batch stall) and its
      // real row/album lands progressively.
      const albumIds = []
      const seqItems = []
      const albumSpecs = []
      for (let i = 0; i < mediaTiles.length; i += this.maxAlbum()) {
        const batch = mediaTiles.slice(i, i + this.maxAlbum())
        const cid = this.uuid()
        albumIds.push(cid)
        albumSpecs.push({ cid, count: batch.length })
        // The caption rides only the FIRST album (matches attachment_steps).
        const cap = i === 0 ? caption : ""
        // Mint a per-photo client_id per tile (phase D: each tile gets its OWN ring + cancel
        // keyed by this id). Queue each photo (looked up in edenFiles by its tile key) under
        // this album — the album message is posted once all its photos have uploaded.
        const photoCids = batch.map(() => this.uuid())
        batch.forEach((tile, j) => {
          const key = this.tileFileKey(tile)
          if (!key) return
          // The staged tile already measured the media's pixel size for the optimistic
          // node — carry it so a video reserves its box server-side without a synchronous
          // ffprobe (#231). Images ignore it (server reads their header).
          const el = tile.querySelector(".ed-compose__img, .ed-compose__video")
          seqItems.push({
            kind: "media",
            albumCid: cid,
            clientId: photoCids[j],
            key,
            w: (el && (el.naturalWidth || el.videoWidth)) || 0,
            h: (el && (el.naturalHeight || el.videoHeight)) || 0,
          })
        })
        // No armStall here: items upload ONE at a time, so the watchdog is armed per-item
        // in pumpSeq when it starts (arming all nodes at Send would false-fail items still
        // WAITING their turn once a slow batch runs past the 90s timeout). Pass the per-photo
        // ids so each tile can carry its own ring + cancel-X.
        if (asFileDocs) this.addOptimisticAsFile(cid, batch, cap, photoCids)
        else this.addOptimisticMedia(cid, batch, cap, photoCids)
      }
      const fileCids = []
      ;[...overlay.querySelectorAll(".ed-attach-file[data-ref]")].forEach((fe) => {
        const cid = this.uuid()
        // The stash key (name:size:lastModified) so a failed card can look its File
        // back up in edenFiles and re-send it.
        const key = fe.dataset.name + ":" + fe.dataset.sizeRaw + ":" + fe.dataset.modified
        // Armed per-item in pumpSeq (see the album note above), not here.
        this.addOptimisticFile(cid, fe.dataset.ref, fe.dataset.name, fe.dataset.size, key)
        fileCids.push(cid)
        // sizeLabel (the human-readable size) rides so a reload can rebuild the file card
        // from the durable record without re-deriving it (phase E).
        seqItems.push({
          kind: "file",
          clientId: cid,
          key,
          sizeLabel: fe.dataset.size,
        })
      })
      // A files-only caption rides BELOW the whole pile as its own trailing message
      // (#149) — draw its optimistic text node after the file cards. A photo+caption
      // keeps the caption on the album (drawn above).
      let captionId = null
      if (!hasMedia && caption && fileCids.length > 0) {
        captionId = this.uuid()
        // Tag the caption's node with the conversation too (#144), so it survives a
        // switch alongside its file cards instead of vanishing until the real
        // trailing message (sent server-side after the last file) lands.
        const capNode = this.addOptimistic(captionId, caption)
        if (capNode) capNode.dataset.convId = this.convId
      }
      // Open the send: the server pins the conversation, mints a group_id for a multi-file
      // send (≥2 files → merged bubble), cancels the now-superseded staged :attachment tray,
      // and replies the group_id (stamped on the file group). Then pump the items one at a
      // time. #122 asFile rides so photos store uncompressed + render as documents.
      const queueId = this.uuid()
      // Fuse the file rows into the merged bubble IMMEDIATELY (before the server's group_id
      // round-trips) so they never flash as separate cards for a frame. A temporary marker
      // (the queueId) groups them now; the queue_start reply then swaps in the real group_id
      // at the same positions (no reflow). Only for a multi-file send (the server groups ≥2).
      if (fileCids.length >= 2) {
        fileCids.forEach((cid) => {
          const row = this.pending?.querySelector(`[data-client-id="${cid}"]`)
          if (row) row.dataset.groupId = queueId
        })
        this.reGroupOptimistic(queueId)
      }
      // Persist each item (its File + metadata) to IndexedDB BEFORE the send (phase E) so a
      // reload mid-upload can resume it from the durable blob. Best-effort — no-ops if the
      // store is unavailable. `storeId` lets seq_done / cancel drop the record as items resolve.
      const store = window.__edenSendStore
      const userId = this.el.dataset.senderId
      const createdAt = Date.now()
      const records = []
      seqItems.forEach((it, order) => {
        it.storeId = queueId + ":" + order
        const f = store && this.el.edenFiles?.get(it.key)
        if (!f) return
        const rec = {
          id: it.storeId,
          userId,
          queueId,
          order,
          convId: this.convId,
          caption,
          captionId,
          asFile,
          kind: it.kind,
          albumCid: it.albumCid || null,
          clientId: it.clientId,
          groupId: null,
          name: f.name,
          sizeLabel: it.sizeLabel || null,
          type: f.type,
          file: f,
          status: "queued",
          createdAt,
        }
        records.push(rec)
        store.put(rec)
      })
      if (store) store.requestPersist()
      this.pushEvent(
        "queue_start",
        {
          queue_id: queueId,
          caption,
          caption_id: captionId,
          as_file: asFile,
          albums: albumSpecs,
          file_cids: fileCids,
        },
        (reply) => {
          const gid = reply && reply.group_id
          if (gid) this.stampGroup(fileCids, gid)
          // Re-put the full records with the server-minted group_id (upsert — robust even if
          // the initial put hasn't committed yet, so no lost-group-id race), so a resumed row
          // rejoins its merged bubble.
          if (store && gid) records.forEach((rec) => store.put({ ...rec, groupId: gid }))
          ;(this.seqQueues = this.seqQueues || []).push({ queueId, items: seqItems })
          this.pumpSeq()
        },
      )
      // Mark the send in flight (#130 polish): updated() then re-hides the
      // overlay on EVERY patch until a fresh pick. Without this, a re-render
      // that beats the media_sending round-trip — or morphdom resetting the
      // inline display:none below to the server's markup — flashes the
      // preview back for a frame after Send (visible under screen-recording
      // load, where transients stretch to several frames).
      this.sending = true
      // Pause any previewed clip first: a played <video> left running while the
      // overlay goes display:none keeps the media session active and flashes the OS
      // media-controls HUD until the server re-render tears the overlay down.
      overlay.querySelectorAll("video").forEach((v) => {
        try {
          v.pause()
        } catch (_e) {
          /* a detached/!ready element can throw — ignore */
        }
      })
      // Close the preview INSTANTLY (#111) instead of waiting for the
      // media_sending round-trip to re-render — on a slow link the overlay
      // lingered ~seconds after Send. The element stays in the DOM (display
      // none) so the in-flight upload bound to its file input isn't dropped;
      // the server render then swaps it for the normal composer.
      overlay.style.display = "none"
      // Glue the room to the bottom through the multi-stage media settle (#104).
      window.dispatchEvent(new CustomEvent("ed:after-send"))
      // Sequential send owns the upload now (feeds :attachment_seq itself): stop the form
      // submit so the staged :attachment entries don't ALSO upload concurrently.
      e.preventDefault()
      e.stopPropagation()
      return
    }
    // A quote-reply (#71) also defers to the server path so the reply_to_id
    // rides along and the quote renders at the right height (no optimistic
    // node that would pop taller when the real row streams in). An edit (#164)
    // defers too — it updates an existing row, so there's no optimistic node.
    if (this.el.querySelector("[data-reply-active], [data-edit-active], [data-forward-active]")) {
      window.dispatchEvent(new CustomEvent("ed:after-send"))
      return
    }
    // Take over text sends: stop the event reaching LiveView's delegated
    // phx-submit so the message isn't also sent without a client_id.
    e.preventDefault()
    e.stopPropagation()
    const body = (this.input.value || "").trim()
    if (!body) return
    this.input.value = ""
    // Oversized bodies (> the server's codepoint cap) are split into
    // ordered parts and sent as separate messages — Telegram-style —
    // instead of failing the whole send (#68). Each part is a normal
    // queued item (own client_id, optimistic node, dedup, resend).
    for (const part of this.split(body)) {
      const clientId = this.uuid()
      // EVERY surface draws an optimistic node NOW (#351) so a "sending" state shows
      // immediately — valuable on a slow cross-border link, and a dropped connection no
      // longer looks like a silent no-op (the old #130 no-node path made rooms/groups send
      // in total silence). The real row carries data-client-id, so the riser swaps it in
      // atomically. A 1:1 DM shows the sending clock (→ ✓ → ✓✓ on read); ROOMS (flat) +
      // GROUPS (no receipt) render a FADED row with no clock — the fade IS the pending
      // indicator. A nack flags whichever node in markFailed (which now finds it, not
      // materializes a duplicate).
      this.addOptimistic(clientId, part)
      this.queue.push({ clientId, body: part, sent: false })
    }
    // Glue to the bottom on our OWN send (#187): rooms (flat) and groups draw no
    // optimistic node — and the node is what scrolls a 1:1 DM down (addOptimistic) — so
    // without this a text send while scrolled up leaves you stranded mid-history. The
    // media + quote-reply paths already dispatch this; mirror it here. onAfterSend is
    // send-only, so reading history (scrolling up without sending) is never yanked.
    window.dispatchEvent(new CustomEvent("ed:after-send"))
    this.flush()
  },
  // A v4 UUID for the client_id. `crypto.randomUUID` only exists in a
  // secure context (HTTPS or localhost); over plain HTTP by IP it's
  // undefined and would throw, silently killing every text send. Fall back
  // to `crypto.getRandomValues`, which IS available in insecure contexts.
  uuid() {
    if (crypto.randomUUID) return crypto.randomUUID()
    const b = crypto.getRandomValues(new Uint8Array(16))
    b[6] = (b[6] & 0x0f) | 0x40
    b[8] = (b[8] & 0x3f) | 0x80
    const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("")
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
  },
  // Break a body into <=max-codepoint chunks, preferring the last space
  // before the limit so words aren't cut; a single unbroken run is hard
  // cut. Counts codepoints (spread handles surrogate pairs) to match the
  // server's `count: :codepoints` and never split a multi-byte char.
  split(body) {
    const max = Number(this.el.dataset.maxBody) || 4000
    const cp = [...body]
    if (cp.length <= max) return [body]
    const parts = []
    let rest = cp
    while (rest.length > max) {
      let cut = max
      const window = rest.slice(0, max).join("")
      const space = window.lastIndexOf(" ")
      if (space > 0) cut = [...window.slice(0, space)].length
      parts.push(rest.slice(0, cut).join("").trim())
      rest = rest.slice(cut)
      // Drop a single boundary space so it isn't doubled across parts.
      if (rest[0] === " ") rest = rest.slice(1)
    }
    const tail = rest.join("").trim()
    if (tail) parts.push(tail)
    return parts.filter((p) => p.length > 0)
  },
  flush() {
    // Items stay queued until acked; only then are they removed. An
    // in-flight item (sent) isn't re-sent until a reconnect re-arms it.
    for (const item of this.queue) {
      if (item.sent) continue
      // Arm the delivery watchdog BEFORE the connection gate (#142): a send
      // composed while offline can't go out now, but must still flip to a red
      // ●! after the offline grace (navigator.onLine picks 20s online / 3s
      // offline) instead of a clock stuck forever. Cleared on the reply.
      this.armSendWatchdog(item.clientId, item.body)
      if (!this.connected) continue
      item.sent = true
      this.pushEvent("send", { message: { body: item.body, client_id: item.clientId } }, (reply) => {
        this.clearSendWatchdog(item.clientId)
        this.queue = this.queue.filter((q) => q.clientId !== item.clientId)
        // On success DON'T remove the optimistic node here — the ack
        // races the {:new_message} broadcast, and removing first leaves
        // a frame where the message vanishes (the list dips, then the
        // real row pops in: the "jerk"). The rise-in observer removes it
        // atomically the instant the real row streams in. A nack (server
        // rejection) drops the item from the queue and flags it failed.
        if (reply && reply.nack) this.markFailed(item.clientId, item.body)
      })
    }
  },
  // Delivery watchdog (#142). Online → ~20s (spans several reconnects); offline
  // → ~3s grace. Fires only if the item is still unacked (a reply clears it).
  armSendWatchdog(clientId, body) {
    this.clearSendWatchdog(clientId)
    const ms = navigator.onLine ? 20000 : 3000
    const timer = setTimeout(() => {
      this.sendTimers.delete(clientId)
      if (this.queue.some((q) => q.clientId === clientId)) this.markFailed(clientId, body)
    }, ms)
    this.sendTimers.set(clientId, timer)
  },
  clearSendWatchdog(clientId) {
    const t = this.sendTimers.get(clientId)
    if (t) { clearTimeout(t); this.sendTimers.delete(clientId) }
  },
  // The browser dropped its network: shorten every pending send's wait to the
  // offline grace so a genuine outage surfaces the red ●! quickly (a momentary
  // blip self-heals before the grace elapses).
  onWentOffline() {
    for (const item of this.queue) this.armSendWatchdog(item.clientId, item.body)
  },
  addOptimistic(clientId, body) {
    // Match the conversation's layout so the optimistic node doesn't
    // flash as a DM bubble in a room (or vice versa) before the real
    // message arrives. body/name are set via textContent, never
    // interpolated into innerHTML — the template strings are static.
    const row = document.createElement("div")
    row.dataset.clientId = clientId
    row.dataset.body = body
    if (this.el.dataset.layout === "flat") {
      // Mirror the server's compact rule (same author within 5 min):
      // a continuation row drops the avatar/name. Without this the
      // optimistic node always drew the avatar, which then vanished a
      // frame later when the real (compact) row replaced it.
      const myId = this.el.dataset.senderId
      const last = this.lastFlatRow()
      const compact = !!last && last.dataset.senderId === myId &&
        (Date.now() / 1000 - Number(last.dataset.ts || 0)) < 300
      row.className = compact ? "ed-flat ed-flat--compact" : "ed-flat"
      row.style.opacity = "0.55"
      row.dataset.senderId = myId
      row.dataset.ts = Math.floor(Date.now() / 1000)
      const name = this.el.dataset.senderName || ""
      if (compact) {
        row.innerHTML =
          '<div class="ed-flat__gutter"></div>' +
          '<div class="ed-flat__main"><div class="break-words ed-flat__body"></div></div>'
      } else {
        row.innerHTML =
          '<div class="ed-flat__gutter"><span class="ed-avatar ed-avatar--sm"><span></span></span></div>' +
          '<div class="ed-flat__main"><div class="ed-flat__head">' +
          '<span class="ed-flat__name"></span></div>' +
          '<div class="break-words ed-flat__body"></div></div>'
        row.querySelector(".ed-avatar span").textContent =
          (name.trim().charAt(0) || "?").toUpperCase()
        row.querySelector(".ed-flat__name").textContent = name
      }
      row.querySelector(".ed-flat__body").textContent = body
    } else {
      // Match the real row's classes exactly ("ed-msg flex justify-end"):
      // .ed-msg carries the inter-message spacing, so the optimistic and
      // real rows are the same height and the swap doesn't nudge layout.
      row.className = "ed-msg flex justify-end"
      const bubble = document.createElement("div")
      bubble.className = "ed-bubble ed-bubble--me"
      bubble.style.opacity = "0.55"
      // Mirror the REAL bubble exactly — body + meta inside .ed-bubble__cap —
      // so the optimistic node is the same height and the riser's swap doesn't
      // nudge layout (#130). The status slot shows a "sending" clock in 1:1s
      // (#142, clock → ✓ → ✓✓ once the real row swaps in); group bubbles render
      // no receipt (the real row hides it for groups), so leave it empty there
      // (#89) — markFailed overwrites whatever's here with the red ●! on a nack.
      const isGroup = this.el.dataset.isGroup === "true"
      const status =
        isGroup
          ? ""
          : '<span class="inline-flex items-center" style="margin-left:2px;">' +
            '<svg class="size-3.5" viewBox="0 0 16 16" fill="none" aria-hidden="true">' +
            '<circle cx="8" cy="8" r="6.25" stroke="currentColor" stroke-width="1.5"/>' +
            '<line class="ed-clock__h" x1="8" y1="8" x2="8" y2="5.4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>' +
            '<line class="ed-clock__m" x1="8" y1="8" x2="8" y2="4.2" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>' +
            '</svg></span>'
      bubble.innerHTML =
        '<div class="ed-bubble__cap">' +
        '<span class="break-words"></span>' +
        '<span class="ed-bubble__meta"><time></time>' + status + "</span>" +
        "</div>"
      bubble.querySelector("span.break-words").textContent = body
      bubble.querySelector("time").textContent =
        new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
      row.appendChild(bubble)
    }
    // Target the send's pane (#348): a thread send sets this._sendTarget so the node lands
    // in #thread-pending; the main send leaves it null (→ this.pending).
    const pend = (this._sendTarget && this._sendTarget.pending) || this.pending
    pend.appendChild(row)
    // Entrance (#456 float-up, #439 timing forensics). Two bugs lived here:
    // (1) the cleanup timeout was still the old fade-era 150ms — REMOVING the
    // class mid-animation cancels it and the row SNAPPED to rest ("резкая");
    // it must outlive the longest variant (340ms touch). (2) the class rode the
    // initial insert, so the animation clock started at style-resolution — on
    // the phone the post-send main-thread work ate the first 100-200ms before
    // anything painted and only the tail showed. Two rAFs = the row has PAINTED
    // (held invisible by inline opacity, no flash), then the full run plays
    // from its first visible frame. The ack handoff reads computed transform/
    // opacity either way, so a fast swap stays seamless.
    row.style.opacity = "0"
    let entered = false
    const enter = () => {
      if (entered) return
      entered = true
      row.style.opacity = ""
      row.classList.add("ed-msg--sent")
      setTimeout(() => row.classList.remove("ed-msg--sent"), 420)
    }
    requestAnimationFrame(() => requestAnimationFrame(enter))
    // rAF is frozen in a backgrounded tab (#461 review) — the timeout twin makes
    // sure a send-then-background can never leave the row invisible.
    setTimeout(enter, 300)
    // The MAIN pane's send-scroll is owned by ScrollBottom's onAfterSend (pins synchronously
    // in this same tick — #351), so no scroll here; a smooth scrollTo only fought that instant
    // pin (the real-row swap cut it off mid-glide — the visible jerk). A THREAD send (#348) has
    // no onAfterSend, so pin its own pane instantly here.
    const scr = this._sendTarget && this._sendTarget.scroller
    if (scr) scr.scrollTop = scr.scrollHeight
    return row
  },
  // Optimistic media node (#95): a local preview of the staged photos with a
  // determinate progress ring, tagged with the send's client_id so the riser
  // observer swaps exactly this twin when the real row streams in. Previews
  // are snapshotted to data-URLs because the overlay's object URLs are
  // revoked on consume. A files-only send (no image/video preview) gets NO
  // node — files render as cards with no meaningful local preview, and an
  // empty album box would just flash; their real rows rise in normally.
  addOptimisticMedia(clientId, composeTiles, caption, photoCids) {
    // Snapshot every staged tile's frame IN ORDER — a photo's <img> or a
    // loaded video's first frame (#117). So a sent clip rises in with its
    // poster at full size, not a blank square that the real video later
    // pops into. A tile whose frame can't be grabbed yet falls back to a
    // fill so the album's tile count still matches the real row.
    // Snapshot each tile's frame AND its source pixel dimensions — the dims let
    // the lone-image case reserve its display box exactly like the real row.
    // `composeTiles` is ONE album's worth of compose tiles (#193): the caller splits a
    // big pick into batches of maxAlbum and builds a node per batch, so each album
    // appears and uploads on send, mirroring the server's per-album split.
    const allTiles = composeTiles.map((tile, i) => {
      const el = tile.querySelector(".ed-compose__img, .ed-compose__video")
      return {
        url: this.snapshot(el),
        w: (el && (el.naturalWidth || el.videoWidth)) || 0,
        h: (el && (el.naturalHeight || el.videoHeight)) || 0,
        video: !!el && el.tagName === "VIDEO",
        name: tile.dataset.name || "",
        size: tile.dataset.size || "",
        // The photo's own client_id (phase D) → drives its per-tile ring + cancel.
        cid: (photoCids && photoCids[i]) || null,
      }
    })
    if (allTiles.length === 0) return
    // A very wide/tall PHOTO (aspect > 5:1) renders as a file card, not inline —
    // mirror the server's strip_photo?/1 so the optimistic node matches the real row
    // (no inline-image → file-card jump on swap). Videos always stay inline.
    const isStrip = (t) =>
      !t.video && t.w > 0 && t.h > 0 && Math.max(t.w, t.h) / Math.min(t.w, t.h) > 5
    const tiles = allTiles.filter((t) => !isStrip(t))
    const strips = allTiles.filter(isStrip)
    const n = tiles.length

    // Match the REAL render so the swap doesn't reflow (#95 review): a message with a
    // SINGLE attachment renders via attachment_view (natural aspect, NOT a square album
    // tile); 2+ use the .ed-album grid. A lone inline photo that rides ALONGSIDE a strip
    // is still a ≥2-attachment message, so the server lays it out as a 1-tile mosaic —
    // hence the `strips.length === 0` guard (else the box→mosaic differ on swap).
    let media = null
    if (n === 1 && tiles[0].url && strips.length === 0) {
      const { w, h, video } = tiles[0]
      media = document.createElement("div")
      const img = document.createElement("img")
      img.src = tiles[0].url
      img.alt = ""
      if (video && w > 0 && h > w) {
        // Portrait video: match the real wide 4:5 box + ambient glow (snapshot as
        // the --vthumb backlight) so the optimistic→real swap doesn't jump narrow→wide.
        media.className = "ed-media-sending ed-media-sending--single ed-video-box--portrait"
        media.style.cssText =
          "--vthumb:url('" + tiles[0].url + "'); width:min(20rem,80vw); aspect-ratio:4/5;"
        img.className = "ed-video"
        media.appendChild(img)
      } else {
        media.className = "ed-media-sending ed-media-sending--single"
        // Reserve the display box exactly like img_box/1 on the real <img>: an
        // explicit width + aspect-ratio. Without it the data-URL's natural size
        // (up to 800px) drove the bubble to its max while the img capped at 320,
        // leaving empty space to the right — and the box collapsed-then-grew.
        img.style.maxWidth = "100%"
        img.style.height = "auto"
        if (w > 0 && h > 0) {
          const scale = Math.min(320 / w, 320 / h, 1)
          img.style.width = Math.round(w * scale) + "px"
          img.style.aspectRatio = w + " / " + h
        } else {
          // A video sent before its metadata loaded (videoWidth === 0): no exact
          // box yet, but cap the width so the data-URL's natural size can't blow
          // the bubble to its max (the empty-space bug) while it settles.
          img.style.width = "min(20rem, 100%)"
        }
        media.appendChild(img)
      }
    } else if (n >= 1) {
      // Justified mosaic matching the real album_view (AlbumLayout.rows/1): split into the
      // SAME aspect-balanced rows the server uses (balanceRows), each tile flex-grown by
      // its aspect, so the optimistic→real swap doesn't reflow. (A count-based split here
      // would regroup mixed-aspect rows on swap; a fixed-column grid left a bg strip.)
      media = document.createElement("div")
      media.className = "ed-album ed-media-sending"
      for (const rowTiles of this.balanceRows(tiles)) {
        const row = document.createElement("div")
        row.className = "ed-album__row"
        row.style.aspectRatio = String(
          rowTiles.reduce((s, t) => s + this.albumAspect(t), 0),
        )
        for (const t of rowTiles) {
          const tile = document.createElement("span")
          tile.className = "ed-album__tile"
          tile.style.flex = this.albumAspect(t) + " 1 0"
          if (t.url) {
            const img = document.createElement("img")
            img.src = t.url
            img.alt = ""
            tile.appendChild(img)
          } else {
            tile.innerHTML = '<span class="ed-album__tile-fill"></span>'
          }
          // Phase D: each tile carries its OWN progress ring + cancel-X, keyed by the photo's
          // client_id — so its upload fills its own arc and the X drops just that photo.
          this.addTileControls(tile, t.cid)
          row.appendChild(tile)
        }
        media.appendChild(row)
      }
    }
    // Strip photos render as file cards (mirrors @rest in album_view) after the
    // inline media — one per strip, with a snapshot thumb + name + size.
    const stripCards = strips.map((t) => {
      const card = document.createElement("div")
      card.className = "ed-file ed-file--photo ed-file--sending"
      const thumb = document.createElement("span")
      thumb.className = "ed-file__thumb"
      if (t.url) {
        const img = document.createElement("img")
        img.src = t.url
        img.alt = ""
        thumb.appendChild(img)
      }
      card.appendChild(thumb)
      const meta = document.createElement("span")
      meta.className = "ed-file__meta"
      const nm = document.createElement("span")
      nm.className = "ed-file__name"
      nm.textContent = t.name
      const sz = document.createElement("span")
      sz.className = "ed-file__size"
      sz.textContent = t.size
      meta.appendChild(nm)
      meta.appendChild(sz)
      card.appendChild(meta)
      return { card, thumb }
    })
    // Invariant from here on: `media` and `stripCards` are never both empty. The early
    // `allTiles.length === 0` return guarantees ≥1 tile; a tile is either inline media
    // (→ `media`) or a strip (→ `stripCards`). So `media || stripCards[0]` always resolves.
    //
    // Per-PHOTO ring + cancel (phase D): each photo fills its OWN arc and its X drops just
    // that photo (the album sends with the rest). Mosaic tiles got theirs above; a LONE
    // inline photo and each strip card get theirs here.
    if (media && n === 1) this.addTileControls(media, tiles[0].cid)
    stripCards.forEach(({ thumb }, k) => this.addTileControls(thumb, strips[k].cid))

    // No strips (the common path): the inline media node IS the content. With strips,
    // the inline media (if any) and the strip cards stack as siblings inside .ed-media.
    let content
    if (stripCards.length === 0) {
      content = media
    } else {
      content = document.createElement("div")
      content.className = "ed-media-sending__group"
      if (media) content.appendChild(media)
      for (const { card } of stripCards) content.appendChild(card)
    }

    const row = this.wrapAndAppendOptimistic(content, clientId, caption)
    // Stash this album's File keys + caption so a failed card can re-send the whole album.
    const keys = composeTiles.map((t) => this.tileFileKey(t)).filter(Boolean)
    if (row && keys.length) {
      row.dataset.fileKeys = JSON.stringify(keys)
      row.dataset.caption = caption || ""
    }
    return row
  },
  // Optimistic node for a photos-only "Send as file" album (#122): mirror the real
  // render — each photo as a document card (snapshot thumb + name + size), never an
  // inline album — so a slow upload doesn't show an album that reshapes into cards on
  // swap. One ring + one cancel for the whole album (its single client_id), matching
  // addOptimisticMedia's model. data-name/size ride the staged tiles.
  addOptimisticAsFile(clientId, tiles, caption, photoCids) {
    // `tiles` is ONE album's worth (#193) — the caller splits a big pick into batches.
    if (tiles.length === 0) return null
    const wrap = document.createElement("div")
    wrap.className = "ed-asfile-sending"
    tiles.forEach((tile, i) => {
      const card = document.createElement("div")
      card.className = "ed-file ed-file--photo ed-file--sending"
      const thumb = document.createElement("span")
      thumb.className = "ed-file__thumb"
      const url = this.snapshot(tile.querySelector(".ed-compose__img"))
      if (url) {
        const img = document.createElement("img")
        img.src = url
        img.alt = ""
        thumb.appendChild(img)
      }
      // Phase D: each "send as file" card fills its OWN ring + cancel-X (its X drops just
      // that photo). data-item-cid on the card → its progress + cancel + stall route to it.
      const cid = photoCids && photoCids[i]
      if (cid) {
        card.dataset.itemCid = cid
        card.classList.add("ed-tile--sending")
        thumb.appendChild(this.buildRing("ed-file__ring"))
        thumb.appendChild(this.buildCancel(() => this.cancelSeqPhoto(cid)))
      }
      card.appendChild(thumb)
      const meta = document.createElement("span")
      meta.className = "ed-file__meta"
      const nm = document.createElement("span")
      nm.className = "ed-file__name"
      nm.textContent = tile.dataset.name || ""
      const sz = document.createElement("span")
      sz.className = "ed-file__size"
      sz.textContent = tile.dataset.size || ""
      meta.appendChild(nm)
      meta.appendChild(sz)
      card.appendChild(meta)
      wrap.appendChild(card)
    })
    // Document cards, not inline media → the normal padded bubble (isFile).
    const row = this.wrapAndAppendOptimistic(wrap, clientId, caption, true)
    // Stash the album's File keys + the as-file flag so a failed card re-sends as docs.
    const keys = tiles.map((t) => this.tileFileKey(t)).filter(Boolean)
    if (row && keys.length) {
      row.dataset.fileKeys = JSON.stringify(keys)
      row.dataset.asFile = "true"
      row.dataset.caption = caption || ""
    }
    return row
  },
  // Mirror album_row_sizes/1 (server): the count plan for N media (4→2+2, a trailing
  // remainder of 1 folded into 2+2). Only its LENGTH is used now — it sets how many
  // rows balanceRows fills; the actual per-row split is aspect-balanced below.
  // The album cap (server's @max_album_entries, #193) — one album's worth of media.
  // A pick beyond it stages whole (max_staged_entries) and the server splits it into
  // albums of this size; the optimistic node mirrors only the first.
  maxAlbum() {
    return Number(this.el.dataset.maxAlbum) || 10
  },
  // Most media one pick may stage at once (server's max_staged_entries, #193). A pick
  // past it is capped in onPick (the config can't take more, and the excess would wedge
  // the whole upload); what stages is split into albums of maxAlbum server-side.
  maxStaged() {
    return Number(this.el.dataset.maxStaged) || 50
  },
  albumRowSizes(n) {
    if (n <= 3) return [n]
    if (n === 4) return [2, 2]
    const r = n % 3
    if (r === 0) return Array(n / 3).fill(3)
    if (r === 1) return Array(Math.floor(n / 3) - 1).fill(3).concat([2, 2])
    return Array(Math.floor(n / 3)).fill(3).concat([2])
  },
  // Mirror album_aspect/1 (server): an item's display aspect, clamped to [0.5, 2.6] and
  // rounded to 4dp so the optimistic flex-grow/row-height math matches the real render
  // exactly (sub-pixel-faithful, no drift on swap). Missing dims fall back to square.
  albumAspect(t) {
    return t.w > 0 && t.h > 0
      ? Math.round(Math.min(2.6, Math.max(0.5, t.w / t.h)) * 1e4) / 1e4
      : 1
  },
  // Mirror chunk_album_rows/1 + balance_rows/3 (server): split tiles into the SAME
  // number of rows as the count plan, but distribute by aspect so each row's aspect-sum
  // is ~equal (→ rows of ~equal height). Uniform photos reproduce the clean count grid;
  // mixed aspects group identically to the server, so the swap never reshuffles rows.
  balanceRows(tiles) {
    const r0 = this.albumRowSizes(tiles.length).length
    const balance = (items, r) => {
      if (r <= 1) return [items]
      const target = items.reduce((s, t) => s + this.albumAspect(t), 0) / r
      const row = []
      let sum = 0
      let i = 0
      while (i < items.length) {
        // Always take ≥1 (row empty); always leave ≥1 for each of the r-1 remaining
        // rows; otherwise fill toward the target aspect-sum.
        if (row.length > 0 && (items.length - i <= r - 1 || sum >= target)) break
        row.push(items[i])
        sum += this.albumAspect(items[i])
        i++
      }
      return [row, ...balance(items.slice(i), r - 1)]
    }
    return balance(tiles, r0)
  },
  // Build the determinate progress ring (#95/#149): a faint track + a fill arc.
  // `cls` styles/sizes the container per context (media = white-on-scrim overlay;
  // file = currentColor, sized to the icon slot). The fill/track circle classes
  // stay shared so setRing drives either one unchanged (same r=16 geometry).
  buildRing(cls) {
    const ring = document.createElement("span")
    ring.className = cls
    ring.setAttribute("aria-hidden", "true")
    ring.innerHTML =
      '<svg viewBox="0 0 36 36">' +
      '<circle class="ed-media-sending__ring-track" cx="18" cy="18" r="16"></circle>' +
      '<circle class="ed-media-sending__ring-fill" cx="18" cy="18" r="16"></circle>' +
      "</svg>"
    return ring
  },
  // An in-flight cancel-X for an optimistic upload node (#137): runs onClick (which
  // aborts the upload + removes the node). Reused on the file card and the media node.
  buildCancel(onClick) {
    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = "ed-sending-cancel"
    btn.setAttribute("aria-label", this.el.dataset.cancelLabel || "Cancel")
    btn.innerHTML = window.edIcon("hero-x-mark-micro", "size-3.5")
    btn.addEventListener("click", (e) => {
      e.preventDefault()
      e.stopPropagation()
      onClick()
    })
    return btn
  },
  // The edenFiles key (name:size:lastModified) for a staged compose tile — read off the
  // inner <img>/<video>, which carry the raw client_size + client_last_modified. Lets a
  // failed album/photo/video card look its original File(s) back up to re-send.
  tileFileKey(tile) {
    const el = tile.querySelector(".ed-compose__img, .ed-compose__video")
    if (!el) return null
    return (el.dataset.name || "") + ":" + (el.dataset.size || "") + ":" + (el.dataset.modified || "")
  },
  // Re-send failed File(s) through the DEDICATED :attachment_retry channel (#…). Reusing
  // :attachment is unreliable: cancelling its in-flight entry leaves the config unable to
  // accept new entries + races the cancelled upload's late progress (a crash). The retry
  // config is auto_upload and NEVER cancelled, so the clones stage + upload cleanly for
  // every kind (lone photo/video, album, file). Clone each File with a nudged lastModified
  // — a fresh identity so LiveView's identity-dedup doesn't drop it as "already seen" (the
  // original entry carried the same identity). Sequence: stash metadata on the server
  // (retry_prepare) FIRST — its reply guarantees pending_retry is set before the auto-
  // upload finishes — THEN feed the clones. `opts`: {node, cid, files, caption, asFile,
  // media}. On completion the server sends the message + pushes retry_done to settle the
  // card. The reply carries {ok}: only feed when the server accepted this retry — it
  // REFUSES (busy) while another retry is in flight (#310 review P1, single pending slot),
  // in which case we revert the card to failed so the user can retry once it frees.
  retrySend(opts) {
    const fresh = opts.files.map(
      (f) => new File([f], f.name, { type: f.type, lastModified: (f.lastModified || 0) + 1 }),
    )
    this.pushEvent(
      "retry_prepare",
      {
        client_id: opts.cid,
        caption: opts.caption || "",
        as_file: !!opts.asFile,
        media: !!opts.media,
        group_id: opts.groupId || null,
      },
      (reply) => {
        if (reply && reply.ok) {
          const input = this.el.querySelector('input[type="file"][name="attachment_retry"]')
          if (input) this.feedInput(input, fresh)
        } else {
          this.onRetryDone({ id: opts.cid, ok: false })
        }
      },
    )
  },
  // Optimistic card for a file/doc send (#149): files post one message PER file, so
  // each gets its own card + client_id and a determinate ring IN the icon slot
  // (data-upload-ref → the server's per-file media_progress drives it). Mirrors the
  // real .ed-file card so the riser's data-client-id swap doesn't reflow.
  addOptimisticFile(clientId, ref, name, size, key) {
    const card = document.createElement("div")
    // mb-1 mirrors the real attachment_view card (#308 review P3): without it the optimistic
    // bubble is 4px shorter and nudges taller when the real row swaps in.
    card.className = "ed-file ed-file--sending mb-1"
    card.dataset.uploadRef = ref
    // Stash the retry key + display bits so a failed card can re-send its File (#…).
    if (key) card.dataset.fileKey = key
    card.dataset.fileName = name || ""
    card.dataset.fileSize = size || ""
    const label = this.el.dataset.sendingLabel
    // Function replacement so a filename with $-patterns ($&, $1) isn't interpreted.
    if (label) card.setAttribute("aria-label", label.replace("{name}", () => name || ""))
    const icon = document.createElement("span")
    icon.className = "ed-file__icon"
    icon.appendChild(this.buildRing("ed-file__ring"))
    // In-flight cancel (#137) centered INSIDE the ring (Telegram-style): the progress
    // arc tracks around the X. Drops THIS file's queued item (+ aborts it if in flight)
    // and removes its row; a late tap after the swap is a harmless no-op.
    icon.appendChild(
      this.buildCancel(() => {
        this.cancelSeqItem(clientId)
        card.closest(".ed-msg, .ed-flat")?.remove()
      }),
    )
    card.appendChild(icon)
    const meta = document.createElement("span")
    meta.className = "ed-file__meta"
    const nm = document.createElement("span")
    nm.className = "ed-file__name"
    // The raw client filename; the real card shows the server-sanitized name, so a
    // name with stripped chars may shift by a frame on swap (cosmetic, #149).
    nm.textContent = name || ""
    const sz = document.createElement("span")
    sz.className = "ed-file__size"
    sz.textContent = size || ""
    meta.appendChild(nm)
    meta.appendChild(sz)
    card.appendChild(meta)
    // No caption on a file card — a files-only caption rides as its own trailing
    // message below the pile (#149). isFile → the normal padded bubble (not --media).
    return this.wrapAndAppendOptimistic(card, clientId, undefined, true)
  },
  // Wrap an optimistic content node (a media node OR a file card) into a bubble/flat
  // row tagged with its client_id, append it to #pending, animate it in, pin to the
  // bottom, and return the row. One shared seam for every kind (#149), so the riser
  // swap + the stall watchdog treat media and files identically.
  wrapAndAppendOptimistic(content, clientId, caption, isFile = false) {
    const row = document.createElement("div")
    row.dataset.clientId = clientId
    // Tag the conversation that owns this in-flight media/file node (#144): the
    // upload keeps running after you leave (it's pinned to its conversation), so
    // a switch HIDES this node instead of wiping it, and re-shows it on return —
    // background-upload progress survives leaving the chat. Text optimistic twins
    // are intentionally NOT tagged (they stay queue/timer-bound to this chat).
    row.dataset.convId = this.convId
    if (this.el.dataset.layout === "flat") {
      // Mirror the real flat row incl. the compact rule (#95 review): a
      // continuation (same author within 5 min) drops the avatar + name
      // header, matching the optimistic text node.
      const myId = this.el.dataset.senderId
      const last = this.lastFlatRow()
      const compact =
        !!last &&
        last.dataset.senderId === myId &&
        Date.now() / 1000 - Number(last.dataset.ts || 0) < 300
      row.className = compact ? "ed-flat ed-flat--compact" : "ed-flat"
      row.dataset.senderId = myId
      row.dataset.ts = Math.floor(Date.now() / 1000)
      const name = this.el.dataset.senderName || ""
      const main = document.createElement("div")
      main.className = "ed-flat__main"
      if (compact) {
        row.innerHTML = '<div class="ed-flat__gutter"></div>'
      } else {
        row.innerHTML =
          '<div class="ed-flat__gutter"><span class="ed-avatar ed-avatar--sm"><span></span></span></div>'
        row.querySelector(".ed-avatar span").textContent =
          (name.trim().charAt(0) || "?").toUpperCase()
        const head = document.createElement("div")
        head.className = "ed-flat__head"
        head.innerHTML = '<span class="ed-flat__name"></span>'
        head.querySelector(".ed-flat__name").textContent = name
        main.appendChild(head)
      }
      main.appendChild(content)
      // Caption below the content, mirroring the real flat row's .ed-flat__body,
      // so it shows during upload (not only when the real row arrives).
      if (caption) {
        const body = document.createElement("div")
        body.className = "break-words ed-flat__body"
        body.textContent = caption
        main.appendChild(body)
      }
      row.appendChild(main)
    } else {
      row.className = "ed-msg flex justify-end"
      const bubble = document.createElement("div")
      const time = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
      const ticks =
        this.el.dataset.isGroup !== "true"
          ? '<span class="inline-flex items-center" style="margin-left:2px;">' +
            window.edIcon("hero-check-micro", "size-3.5") + '</span>'
          : ""
      if (isFile) {
        // A FILE (or "send as file" docs) keeps the NORMAL padded bubble — mirror
        // message_bubble's media?==false branch: no --media (else the card's own
        // translucent fill stacks on the cobalt bubble as "two bubbles" and the time
        // overlay + cancel-X collide). The card sits in the padded bubble; a normal
        // .ed-bubble__cap holds the optional caption + the meta row (time + ticks).
        // --file gives the steady fixed width (card fills it), matching the real row so the
        // riser's swap doesn't reshape the bubble.
        bubble.className = "ed-bubble ed-bubble--me ed-bubble--file"
        bubble.appendChild(content)
        const cap = document.createElement("div")
        cap.className = "ed-bubble__cap"
        if (caption) {
          const capText = document.createElement("span")
          capText.className = "break-words"
          capText.textContent = caption
          cap.appendChild(capText)
        }
        const meta = document.createElement("span")
        meta.className = "ed-bubble__meta"
        meta.innerHTML = "<time>" + time + "</time>" + ticks
        cap.appendChild(meta)
        bubble.appendChild(cap)
      } else {
        // Real inline media: mirror the media bubble EXACTLY so the optimistic twin is
        // the same height (no swap nudge) and frameless — --media zeroes the padding,
        // media fills .ed-media, the time overlays (no caption) or rides .ed-bubble__cap.
        bubble.className = "ed-bubble ed-bubble--me ed-bubble--media"
        const mediaWrap = document.createElement("div")
        mediaWrap.className = "ed-media"
        mediaWrap.appendChild(content)
        if (!caption) {
          const t = document.createElement("span")
          t.className = "ed-media-time"
          t.innerHTML = "<time>" + time + "</time>" + ticks
          mediaWrap.appendChild(t)
        }
        bubble.appendChild(mediaWrap)
        if (caption) {
          const cap = document.createElement("div")
          cap.className = "ed-bubble__cap ed-bubble__cap--media"
          const capText = document.createElement("span")
          capText.className = "break-words"
          capText.textContent = caption
          cap.appendChild(capText)
          const meta = document.createElement("span")
          meta.className = "ed-bubble__meta"
          meta.innerHTML = "<time>" + time + "</time>" + ticks
          cap.appendChild(meta)
          bubble.appendChild(cap)
        }
      }
      row.appendChild(bubble)
    }
    // Target the send's pane (#348): a thread send sets this._sendTarget → #thread-pending +
    // #thread-scroll; the main send leaves it null (→ this.pending / this.scroller). Captured
    // in locals so the deferred img-load pin uses the right scroller after _sendTarget clears.
    const pend = (this._sendTarget && this._sendTarget.pending) || this.pending
    const scr = (this._sendTarget && this._sendTarget.scroller) || this.scroller
    pend.appendChild(row)
    row.classList.add("ed-msg--enter")
    setTimeout(() => row.classList.remove("ed-msg--enter"), 200)
    // Pin to the just-sent photo. The preview image decodes async (no height yet),
    // so an immediate scroll lands short; re-pin on each image's load too (#104). This
    // keeps us glued to the bottom through the grow, so the photo never hides below
    // the fold even when the grow exceeds the ScrollBottom pinned threshold.
    const pin = () => {
      if (!scr) return
      const smooth = !window.matchMedia("(prefers-reduced-motion: reduce)").matches
      scr.scrollTo({ top: scr.scrollHeight, behavior: smooth ? "smooth" : "auto" })
    }
    pin()
    row.querySelectorAll("img").forEach((img) => {
      if (!img.complete) img.addEventListener("load", pin, { once: true })
    })
    return row
  },
  // Drive the progress ring's fill arc (#95). The dasharray is fixed in CSS
  // (the circle's circumference, r=16); we only move the dashoffset, so 0%
  // hides the arc and 100% closes the ring. A no-op if the node is gone.
  setRing(row, percent) {
    const fill = row && row.querySelector(".ed-media-sending__ring-fill")
    if (!fill) return
    const c = 2 * Math.PI * 16
    const p = Math.max(0, Math.min(100, Number(percent) || 0))
    fill.style.strokeDashoffset = c * (1 - p / 100)
  },
  // Find an optimistic node / album tile by client_id across BOTH pending containers
  // (#pending-messages for the main pane, #thread-pending for the thread panel), so the
  // shared progress / done / cancel / failed handlers drive a thread send's nodes too
  // (parity #348). client_ids are UUIDs — safe unquoted in an attribute selector.
  findNode(id) {
    return (
      this.pending?.querySelector(`[data-client-id="${id}"]`) ||
      document.getElementById("thread-pending")?.querySelector(`[data-client-id="${id}"]`) ||
      null
    )
  },
  findTile(id) {
    return (
      this.pending?.querySelector(`[data-item-cid="${id}"]`) ||
      document.getElementById("thread-pending")?.querySelector(`[data-item-cid="${id}"]`) ||
      null
    )
  },
  // Remove an optimistic media node by client_id (the server names the exact
  // one on failure) and cancel its stall watchdog.
  dropPending(id) {
    const node = this.findNode(id)
    if (!node) return
    if (node._stall) clearTimeout(node._stall)
    node.remove()
  },
  // Stall watchdog (#95/#149): if an upload makes NO progress for 90s WHILE CONNECTED
  // — a dropped link is frozen in disconnected() and resumes on reconnect, so this only
  // fires for a genuinely wedged upload — mark the node FAILED (red !, with resend +
  // delete) instead of silently dropping it. Takes the optimistic ROW directly; every
  // media_progress tick re-arms it, so a merely-slow upload is never killed; a row
  // removed by the swap leaves a harmless dead timer (no-ops once disconnected).
  armStall(node) {
    if (!node) return
    if (node._stall) clearTimeout(node._stall)
    node._stall = setTimeout(() => {
      if (!node.isConnected) return
      const retry = node.dataset.retry === "true"
      // A whole :attachment batch stalls together, but each optimistic card armed its OWN
      // timer — fail the batch AT ONCE and clear the siblings' timers (#309 review P1), so
      // no straggler later fires a second media_send_reset (the double-fire crash race, or
      // nuking a send the user has since re-staged). Skip retry nodes (their own channel).
      if (!retry && this.pending) {
        for (const row of this.pending.children) {
          if (row === node || row.dataset.retry === "true" || !row._stall) continue
          clearTimeout(row._stall)
          row._stall = null
          if (row.querySelector(".ed-file--sending, .ed-media-sending, .ed-asfile-sending")) {
            this.markUploadFailed(row)
          }
        }
      }
      // Client: turn the node into the visible failed state (keeps it, with resend +
      // delete). Server: cancel the wedged staged entries — WITHOUT the flash (the inline
      // ! is the visible failure). Resend re-stages from the File stash; delete drops it.
      this.markUploadFailed(node)
      // A retrying node lives on the dedicated :attachment_retry channel — reset THAT
      // (drop its pristine entries + pending metadata), not the main :attachment send.
      this.pushEvent(retry ? "retry_reset" : "media_send_reset", {})
    }, 90000)
  },
  // A stalled upload → a visible failure the user controls, never a silent drop. Route by
  // the real per-file FILE card: it carries data-upload-ref (#310 review P1) — a "send as
  // file" doc card or an album strip card is ALSO .ed-file--sending but has no ref, so it
  // belongs to the media pile (markMediaFailed offers its row-level Resend), not the file
  // path (which would find no File key → no Resend button).
  markUploadFailed(node) {
    const card = node.querySelector(".ed-file--sending[data-upload-ref]")
    if (card) return this.markFileFailed(card)
    return this.markMediaFailed(node)
  },
  // Turn an in-flight FILE card into a failed one: red !, "Not sent", + Resend
  // (re-uploads the File stashed at pick) + Delete. Re-send works even when the upload
  // wedged with the link up, since the original File is stashed.
  markFileFailed(card) {
    if (card.classList.contains("ed-file--failed")) return
    card.classList.remove("ed-file--sending")
    card.classList.add("ed-file--failed")
    // Drop the bubble's delivery tick (✓) — it never sent, so a "delivered" check next
    // to "Not sent" is contradictory. The time stays; the ! + Resend/Delete carry the state.
    card.closest(".ed-bubble")?.querySelector(".ed-bubble__meta .inline-flex")?.remove()
    const ref = card.dataset.uploadRef
    const icon = card.querySelector(".ed-file__icon")
    if (icon) {
      icon.innerHTML =
        window.edIcon("hero-exclamation-circle-mini", "size-6")
    }
    const notSent = this.el.dataset.notSent || "Not sent"
    const sz = card.querySelector(".ed-file__size")
    if (sz) sz.textContent = notSent
    // Replace the stale "Sending {name}" SR label — it's no longer sending (#310 review P3).
    card.setAttribute("aria-label", (card.dataset.fileName || "") + " — " + notSent)
    const actions = document.createElement("div")
    actions.className = "ed-file__actions"
    const file = card.dataset.fileKey && this.el.edenFiles?.get(card.dataset.fileKey)
    if (file) {
      const retry = document.createElement("button")
      retry.type = "button"
      retry.className = "ed-file__act"
      retry.textContent = this.el.dataset.resend || "Resend"
      retry.addEventListener("click", (e) => {
        e.preventDefault(); e.stopPropagation()
        this.retryFile(card, ref, file)
      })
      actions.appendChild(retry)
    }
    const del = document.createElement("button")
    del.type = "button"
    del.className = "ed-file__act ed-file__act--danger"
    del.textContent = this.el.dataset.delete || "Delete"
    del.addEventListener("click", (e) => {
      e.preventDefault(); e.stopPropagation()
      // The entry was already cancelled when the stall fired (media_send_reset), so
      // just drop the failed card — no cancel_upload (it would raise on the gone ref).
      const node = card.closest(".ed-msg, .ed-flat")
      const gid = node?.dataset.groupId
      node?.remove()
      // Deleting the last failed sibling re-fuses (nothing left) + releases the server hold
      // so the delivered group's tail closes again.
      if (gid) { this.reGroupOptimistic(gid); this.maybeReleaseGroup(gid) }
    })
    actions.appendChild(del)
    card.querySelector(".ed-file__meta")?.appendChild(actions)
    // The failed card is a merged-group member: it's now the group's parked tail. Re-fuse the
    // remaining #pending nodes and hold the delivered group's tail OPEN on the server so it
    // doesn't close (with a time) above this dangling card.
    const gid = card.closest(".ed-msg, .ed-flat")?.dataset.groupId
    if (gid && !this.heldGroups.has(gid)) {
      this.heldGroups.add(gid)
      this.reGroupOptimistic(gid)
      this.pushEvent("group_hold", { group_id: gid })
    }
  },
  // Release the server-side seam hold once a held group has no more #pending nodes (its
  // failed card was resent — and just landed — or deleted): its real tail can close again.
  maybeReleaseGroup(gid) {
    if (!gid || !this.heldGroups.has(gid)) return
    // Match how the hold/delete paths resolve a node — .ed-msg (bubbles) OR .ed-flat (rooms)
    // — so a still-parked card is never missed and the group released early.
    const parked = `.ed-msg[data-group-id="${gid}"], .ed-flat[data-group-id="${gid}"]`
    if (!this.pending?.querySelector(parked)) {
      this.heldGroups.delete(gid)
      this.pushEvent("group_release", { group_id: gid })
    }
  },
  // Re-send a failed file: keep the card in place as the in-flight indicator (restore its
  // sending look via markRetrying), give it a FRESH client_id so the real retry message
  // swaps it in, arm the stall watchdog, and fire the send down the dedicated channel.
  retryFile(card, _ref, file) {
    const node = card.closest(".ed-msg, .ed-flat")
    if (!node) return
    // Inherit the send's group_id so the resent row rejoins its merged file bubble.
    const groupId = node.dataset.groupId || null
    const cid = this.uuid()
    node.dataset.clientId = cid
    this.markRetrying(node)
    this.armStall(node)
    this.retrySend({ files: [file], asFile: false, media: false, caption: "", cid, groupId })
  },
  // Re-send a failed media album / lone photo / video / "send as file" pile from the
  // stashed Files, keeping the node as the in-flight indicator (same channel as files).
  retryMedia(node, keys, asFile) {
    const files = keys.map((k) => this.el.edenFiles?.get(k)).filter(Boolean)
    if (!files.length || files.length !== keys.length) return
    const cid = this.uuid()
    node.dataset.clientId = cid
    this.markRetrying(node)
    this.armStall(node)
    this.retrySend({
      files,
      asFile,
      media: true,
      caption: node.dataset.caption || "",
      cid,
    })
  },
  // Turn a FAILED card back into an in-flight one for the duration of a Resend: drop the
  // failed affordances (! / actions / bar) and restore the sending ring, so a re-failure
  // (retry_done !ok or the stall watchdog) can cleanly re-mark it via markUploadFailed.
  markRetrying(node) {
    node.dataset.retry = "true"
    node.classList.add("ed-msg--retrying")
    const fcard = node.querySelector(".ed-file--failed")
    if (fcard) {
      fcard.classList.remove("ed-file--failed")
      fcard.classList.add("ed-file--sending")
      fcard.querySelector(".ed-file__actions")?.remove()
      const icon = fcard.querySelector(".ed-file__icon")
      if (icon) {
        icon.innerHTML = ""
        icon.appendChild(this.buildRing("ed-file__ring"))
      }
      const sz = fcard.querySelector(".ed-file__size")
      if (sz) sz.textContent = fcard.dataset.fileSize || ""
    }
    // Media pile: dropping the failed bar reveals its ring again.
    node.querySelector(".ed-upload-failed__bar")?.remove()
  },
  // Settle a Resend (#…): on success the real message's client_id swap already removed the
  // node, so just kill its watchdog; on failure re-mark it failed (Resend/Delete return).
  onRetryDone({ id, ok }) {
    const node = this.findNode(id)
    if (!node) return
    if (node._stall) {
      clearTimeout(node._stall)
      node._stall = null
    }
    // No longer retrying, either way: on ok the client_id swap removes the node; on failure
    // re-mark it failed (Resend/Delete return). Clear the retry flag so a stale marker
    // can't misroute a later watchdog to retry_reset.
    delete node.dataset.retry
    if (!ok) {
      node.classList.remove("ed-msg--retrying")
      this.markUploadFailed(node)
    }
  },
  // A failed media album / lone photo / video / "send as file" pile: red ! + Resend
  // (re-sends the whole album from the stashed Files) + Delete. Resend shows only when
  // every File is still stashed (edenFiles) — otherwise the album can't be rebuilt.
  markMediaFailed(node) {
    if (node.querySelector(".ed-upload-failed__bar")) return
    const host = node.querySelector(".ed-media-sending, .ed-asfile-sending") || node
    host.querySelectorAll(".ed-sending-cancel").forEach((c) => c.remove())
    const bar = document.createElement("div")
    bar.className = "ed-upload-failed__bar"
    bar.innerHTML =
      '<span class="ed-upload-failed__bang">' +
      window.edIcon("hero-exclamation-circle-mini", "size-5") + '</span>'
    let keys = []
    try {
      keys = JSON.parse(node.dataset.fileKeys || "[]")
    } catch (_e) {
      keys = []
    }
    const asFile = node.dataset.asFile === "true"
    const haveAll = keys.length > 0 && keys.every((k) => this.el.edenFiles?.has(k))
    if (haveAll) {
      const retry = document.createElement("button")
      retry.type = "button"
      retry.className = "ed-file__act"
      retry.textContent = this.el.dataset.resend || "Resend"
      retry.addEventListener("click", (e) => {
        e.preventDefault(); e.stopPropagation()
        this.retryMedia(node, keys, asFile)
      })
      bar.appendChild(retry)
    }
    const del = document.createElement("button")
    del.type = "button"
    del.className = "ed-file__act ed-file__act--danger"
    del.textContent = this.el.dataset.delete || "Delete"
    del.addEventListener("click", (e) => {
      e.preventDefault(); e.stopPropagation()
      // Entries were already cancelled when the stall fired (media_send_reset), so just
      // drop the failed node — no cancel_all_uploads (redundant; matches the file card).
      node.remove()
    })
    bar.appendChild(del)
    host.appendChild(bar)
  },
  // Snapshot a loaded preview <img> to a persistent JPEG data-URL. Returns
  // null on taint/empty so the node just shows the ring over a blank tile.
  snapshot(el) {
    if (!el) return null
    try {
      // An <img> exposes naturalWidth/Height; a loaded <video> exposes
      // videoWidth/Height (#117). drawImage paints either's current frame.
      let w = el.naturalWidth || el.videoWidth || el.width
      let h = el.naturalHeight || el.videoHeight || el.height
      if (!w || !h) return null
      // Downscale to a preview size (#95 review): a full-res phone photo
      // would allocate a ~tens-of-MB canvas and hold a multi-MB data-URL
      // per tile. 800px on the long edge is ample for the in-stream preview.
      const max = 800
      if (w > max || h > max) {
        const s = max / Math.max(w, h)
        w = Math.round(w * s)
        h = Math.round(h * s)
      }
      const c = document.createElement("canvas")
      c.width = w
      c.height = h
      c.getContext("2d").drawImage(el, 0, 0, w, h)
      return c.toDataURL("image/jpeg", 0.7)
    } catch (_e) {
      return null
    }
  },
  // Capture a local object URL for each staged video at SELECTION time (#117)
  // — the most reliable point, since the upload entry never exposes its File
  // to a hook. Keyed "name:size:lastModified" (deduped, so the input/change
  // pair and the compress re-dispatch don't double-create); .VideoPreview
  // reads it back.
  captureVideoUrls(e) {
    const input = e.target
    if (!(input instanceof HTMLInputElement) || input.type !== "file") return
    for (const f of input.files || []) {
      // name+size alone collide for two different files of equal weight; lastModified
      // adds the distinguishing entropy (it matches entry.client_last_modified).
      const key = f.name + ":" + f.size + ":" + f.lastModified
      // Stash EVERY picked File so a failed upload can be re-sent (the entry's File is
      // gone once cancelled). Keyed the same way as the previews below.
      if (!this.el.edenFiles.has(key)) this.el.edenFiles.set(key, f)
      // video AND image: .VideoPreview + .ImgPreview both read these back. Images use
      // it so the compose preview is OUR crash-safe <img>, not LiveView's
      // <.live_img_preview> (whose mounted() threw createObjectURL(undefined) on a
      // consumed entry mid-send, aborting the patch → empty modal).
      if (!/^(video|image)\//.test(f.type || "")) continue
      if (!this.el.edenVideoUrls.has(key)) {
        this.el.edenVideoUrls.set(key, URL.createObjectURL(f))
      }
    }
  },
  // Re-feed an input with an exact File set so LiveView stages it (set files +
  // dispatch input/change — the proven PasteUpload path). Used to flush a queued
  // batch (#119) into the freed config.
  feedInput(input, files) {
    const dt = new DataTransfer()
    files.forEach((f) => dt.items.add(f))
    input.files = dt.files
    input.dispatchEvent(new Event("input", { bubbles: true }))
    input.dispatchEvent(new Event("change", { bubbles: true }))
  },
  // Thread attachment send (#348): reads the thread's compose overlay — the SAME lightbox as
  // the main composer — and runs the SAME optimistic builders + sequential feeder, but targeting
  // the THREAD pane (#thread-pending / #thread-scroll) and stamping each item as a reply under
  // `rootId`. Called by .ThreadSendQueue.onSubmit (owner = this SendQueue). `stash` is the thread
  // composer's edenFiles (name:size:lastModified → File) so pumpSeq feeds the real bytes.
  threadComposeSend(overlay, rootId, stash) {
    const root_id = Number(rootId)
    if (!Number.isInteger(root_id) || root_id <= 0) return
    // A staged entry with a client-side error won't upload — keep the lightbox open so the
    // error stays visible (mirrors the main send); never fake a node.
    if (overlay.querySelector(".ed-attach-err")) return
    const caption = (overlay.querySelector("[data-compose-caption]")?.value || "").trim()
    const mediaTiles = [...overlay.querySelectorAll(".ed-compose__tile")]
    const hasMedia = mediaTiles.length > 0
    // Target the THREAD pane for every optimistic node this build appends (rings/cancel/failed
    // all land in #thread-pending; the async feed then finds them via findNode/findTile).
    this._sendTarget = {
      pending: document.getElementById("thread-pending"),
      scroller: document.getElementById("thread-scroll"),
    }
    const albumSpecs = []
    const seqItems = []
    for (let i = 0; i < mediaTiles.length; i += this.maxAlbum()) {
      const batch = mediaTiles.slice(i, i + this.maxAlbum())
      const cid = this.uuid()
      albumSpecs.push({ cid, count: batch.length })
      const cap = i === 0 ? caption : ""
      const photoCids = batch.map(() => this.uuid())
      batch.forEach((tile, j) => {
        const key = this.tileFileKey(tile)
        if (!key) return
        const el = tile.querySelector(".ed-compose__img, .ed-compose__video")
        seqItems.push({
          kind: "media",
          albumCid: cid,
          clientId: photoCids[j],
          key,
          file: stash && stash.get(key),
          w: (el && (el.naturalWidth || el.videoWidth)) || 0,
          h: (el && (el.naturalHeight || el.videoHeight)) || 0,
        })
      })
      this.addOptimisticMedia(cid, batch, cap, photoCids)
    }
    const fileCids = []
    ;[...overlay.querySelectorAll(".ed-attach-file[data-ref]")].forEach((fe) => {
      const cid = this.uuid()
      const key = fe.dataset.name + ":" + fe.dataset.sizeRaw + ":" + fe.dataset.modified
      this.addOptimisticFile(cid, fe.dataset.ref, fe.dataset.name, fe.dataset.size, key)
      fileCids.push(cid)
      seqItems.push({
        kind: "file",
        clientId: cid,
        key,
        file: stash && stash.get(key),
        sizeLabel: fe.dataset.size,
      })
    })
    // A files-only caption rides its own trailing reply (like the main composer #149).
    let captionId = null
    if (!hasMedia && caption && fileCids.length > 0) {
      captionId = this.uuid()
      const capNode = this.addOptimistic(captionId, caption)
      if (capNode) capNode.dataset.convId = this.convId
    }
    // Tag every node this build just appended with its owning thread root (#380/R066): the
    // pane (#thread-pending) is shared across a room's threads, so .ThreadSendQueue.updated()
    // keys hide/show on data-thread-root instead of wiping the pane on a thread switch —
    // otherwise an in-flight attachment send to thread A loses its rings when B opens. Only
    // the just-created nodes are untagged; earlier threads' nodes already carry their root.
    for (const node of this._sendTarget.pending.children) {
      if (!node.dataset.threadRoot) node.dataset.threadRoot = String(root_id)
    }
    this._sendTarget = null
    if (!seqItems.length) return
    const queueId = this.uuid()
    this.pushEvent(
      "queue_start",
      {
        queue_id: queueId,
        caption,
        caption_id: captionId,
        as_file: false,
        albums: albumSpecs,
        file_cids: fileCids,
        root_id: root_id,
      },
      () => {
        ;(this.seqQueues = this.seqQueues || []).push({ queueId, items: seqItems })
        this.pumpSeq()
      },
    )
    // Close the lightbox instantly (#111 parity); the server then cancels the staged
    // :thread_attachment entries so they don't ALSO upload via the form submit.
    overlay.querySelectorAll("video").forEach((v) => {
      try { v.pause() } catch (_e) {}
    })
    overlay.style.display = "none"
    window.dispatchEvent(new CustomEvent("ed:after-send"))
  },
  // ── Sequential send feeder (TG-attachments) ──────────────────────────────────────────
  // Feed ONE queued item's clone into :attachment_seq, wait for the server's seq_done, then
  // pump the next. `seqFeeding` guards the single-in-flight invariant (one entry at a time).
  pumpSeq() {
    if (this.seqFeeding) return
    const queue = (this.seqQueues || []).find((q) => q.items.length)
    if (!queue) return
    const item = queue.items[0]
    this.seqFeeding = item
    // Announce the item first (reply-gated, like retry_prepare) so the server's metadata is
    // set before the entry's first progress tick; only feed on ok (it busy-refuses a second
    // item while one is in flight).
    this.pushEvent(
      "seq_item",
      {
        queue_id: queue.queueId,
        client_id: item.clientId,
        kind: item.kind,
        album_cid: item.albumCid || null,
        // Client-measured dims (#231) — a video's box-reservation hint.
        width: item.w || null,
        height: item.h || null,
      },
      (reply) => {
        if (!(reply && reply.ok)) {
          this.seqFeeding = null
          // Busy = another item in flight → retry shortly. Any other refusal (e.g. a stale
          // queue) → drop this item instead of looping forever on it.
          if (reply && reply.busy) setTimeout(() => this.pumpSeq(), 80)
          else this.onSeqDone(item.clientId)
          return
        }
        // A resumed item (phase E) carries its durable blob directly; a fresh send looks the
        // File up in edenFiles by key.
        const f = item.file || this.el.edenFiles?.get(item.key)
        const input = this.el.querySelector('input[type="file"][name="attachment_seq"]')
        if (f && input) {
          // Clone with a nudged lastModified so LiveView's identity-dedup stages it fresh;
          // clear the input first so a just-consumed entry's identity can't block the feed.
          const clone = new File([f], f.name, {
            type: f.type,
            lastModified: (f.lastModified || 0) + 1,
          })
          input.value = ""
          this.feedInput(input, [clone])
          // Arm the stall watchdog for THIS item now that it's actually uploading (queued
          // items stay unarmed until their turn); seq_progress re-arms on each tick. A media
          // photo arms its own TILE (data-item-cid); a file its card row.
          const node = this.pending?.querySelector(
            item.kind === "media"
              ? `[data-item-cid="${item.clientId}"]`
              : `[data-client-id="${item.clientId}"]`,
          )
          this.armSeqStall(node)
        } else {
          // The File is gone (edenFiles cleared / never stashed) — the server already set
          // seq_pending from the reply, so tell it to release the slot + drop this item's
          // count (seq_reset), else the queue can't finalize and later items are refused.
          this.pushEvent("seq_reset", {})
          this.seqFeeding = null
          this.onSeqDone(item.clientId)
        }
      },
    )
  },
  // A queued item finished on the server (its real row/album streamed in and swapped its
  // optimistic node) — drop it from its queue and pump the next.
  onSeqDone(id) {
    this.seqFeeding = null
    // Clear the nodeless (thread) watchdog so a just-finished item can't seq_reset the next.
    if (this._seqStall) {
      clearTimeout(this._seqStall)
      this._seqStall = null
    }
    // A finished album photo: retire its tile's ring + cancel-X (its source is now
    // accumulated server-side, so cancelling it here would only fade the tile while the
    // album still sends it — phase D review). A done photo simply shows clean.
    const tile = this.findTile(id)
    if (tile) {
      tile.classList.remove("ed-tile--sending")
      tile.querySelector(".ed-sending-cancel")?.remove()
      tile.querySelector(".ed-media-sending__ring")?.remove()
    }
    for (const q of this.seqQueues || []) {
      const idx = q.items.findIndex((it) => it.clientId === id)
      if (idx >= 0) {
        this.forgetStored(q.items[idx])
        q.items.splice(idx, 1)
        break
      }
    }
    this.seqQueues = (this.seqQueues || []).filter((q) => q.items.length)
    this.pumpSeq()
  },
  // Drop an item's durable record (phase E) once it's resolved (sent/cancelled/failed), so a
  // later reload doesn't re-upload it. No-op without a store / storeId.
  forgetStored(item) {
    if (item && item.storeId && window.__edenSendStore) window.__edenSendStore.remove(item.storeId)
  },
  // Resume interrupted sends after a reload (phase E): scan the durable store for this user's
  // unfinished items IN THE CURRENT conversation, rebuild their optimistic rows, and re-open
  // + re-feed each queue. Other-conversation queues wait for a load into that chat (they GC
  // after 24h). Idempotent across tabs: the server dedups by client_id, so a redundant resume
  // can't double-send.
  async resumeSends() {
    const store = window.__edenSendStore
    const userId = this.el.dataset.senderId
    if (!store || !userId || !this.pending) return
    let records
    try {
      records = await store.listUnfinished(userId)
    } catch (_e) {
      return
    }
    records = (records || []).filter((r) => String(r.convId) === String(this.convId))
    if (!records.length) return
    const byQueue = new Map()
    for (const r of records) {
      if (!byQueue.has(r.queueId)) byQueue.set(r.queueId, [])
      byQueue.get(r.queueId).push(r)
    }
    for (const [queueId, recs] of byQueue) this.resumeQueue(queueId, recs)
  },
  resumeQueue(queueId, recs) {
    recs.sort((a, b) => a.order - b.order)
    const first = recs[0]
    const items = recs.map((r) => ({
      kind: r.kind,
      albumCid: r.albumCid,
      clientId: r.clientId,
      storeId: r.id,
      file: r.file,
    }))
    // Rebuild the optimistic FILE cards so the resume is visible (a media album re-uploads
    // silently and its real row streams in on completion).
    recs.forEach((r) => {
      if (r.kind !== "file") return
      const node = this.addOptimisticFile(r.clientId, "", r.name || "", r.sizeLabel || "", null)
      if (node && r.groupId) node.dataset.groupId = r.groupId
    })
    const fileCids = recs.filter((r) => r.kind === "file").map((r) => r.clientId)
    const albumMap = new Map()
    recs
      .filter((r) => r.kind === "media")
      .forEach((r) => albumMap.set(r.albumCid, (albumMap.get(r.albumCid) || 0) + 1))
    const albums = [...albumMap.entries()].map(([cid, count]) => ({ cid, count }))
    this.pushEvent(
      "queue_resume",
      {
        queue_id: queueId,
        group_id: first.groupId || null,
        conv_id: first.convId,
        caption: first.caption || "",
        caption_id: first.captionId || null,
        as_file: !!first.asFile,
        albums,
        file_cids: fileCids,
        client_ids: items.map((it) => it.clientId),
      },
      (reply) => {
        if (!(reply && reply.ok)) {
          // Not resumable (conversation gone / left) — drop the durable queue + rebuilt cards.
          window.__edenSendStore?.removeQueue(queueId)
          items.forEach((it) =>
            this.pending?.querySelector(`[data-client-id="${it.clientId}"]`)?.remove(),
          )
          return
        }
        const gid = reply.group_id
        const sent = new Set(reply.already_sent || [])
        const doneAlbums = new Set(reply.done_albums || [])
        const remaining = []
        for (const it of items) {
          const done =
            sent.has(it.clientId) || (it.kind === "media" && doneAlbums.has(it.albumCid))
          if (done) {
            // Delivered before the reload — its real row is already loaded; drop record + card.
            this.forgetStored(it)
            this.pending?.querySelector(`[data-client-id="${it.clientId}"]`)?.remove()
          } else {
            if (gid) {
              const n = this.pending?.querySelector(`[data-client-id="${it.clientId}"]`)
              if (n) n.dataset.groupId = gid
            }
            remaining.push(it)
          }
        }
        // Fuse the rebuilt optimistic file rows into the merged bubble (as at Send).
        if (gid) this.reGroupOptimistic(gid)
        if (remaining.length) {
          ;(this.seqQueues = this.seqQueues || []).push({ queueId, items: remaining })
          this.pumpSeq()
        }
      },
    )
  },
  // Cancel-X on a still-sending file card: drop its queued item so it never sends; if it was
  // the in-flight one, abort the upload (seq_reset frees the slot) and pump the rest.
  cancelSeqItem(clientId) {
    const feeding = this.seqFeeding && this.seqFeeding.clientId === clientId
    let queueId = null
    for (const q of this.seqQueues || []) {
      const idx = q.items.findIndex((it) => it.clientId === clientId)
      if (idx >= 0) { queueId = q.queueId; this.forgetStored(q.items[idx]); q.items.splice(idx, 1) }
    }
    this.seqQueues = (this.seqQueues || []).filter((q) => q.items.length)
    if (feeding) {
      // In flight: seq_reset aborts it AND drops its server-side count.
      this.pushEvent("seq_reset", {})
      this.seqFeeding = null
      this.pumpSeq()
    } else if (queueId) {
      // Queued (never fed): the server still counts it — tell it to drop the count so the
      // queue can finalize (else sending_media stays stuck).
      this.pushEvent("seq_drop", { queue_id: queueId, kind: "file", album_cid: null })
    }
  },
  // Attach a photo's OWN progress ring + cancel-X (phase D) to a tile/thumb, keyed by its
  // client_id. Each photo fills its own arc; the X drops just that photo (the album sends
  // with the rest).
  addTileControls(el, cid) {
    if (!el || !cid) return
    el.dataset.itemCid = cid
    el.classList.add("ed-tile--sending")
    el.appendChild(this.buildRing("ed-media-sending__ring"))
    el.appendChild(this.buildCancel(() => this.cancelSeqPhoto(cid)))
  },
  // Cancel-X on ONE album photo: fade its tile out, drop it from the queue (the server
  // decrements the album's expected — it sends with the rest); abort the upload if this
  // photo is the in-flight one.
  cancelSeqPhoto(cid) {
    const tile = this.findTile(cid)
    const feeding = this.seqFeeding && this.seqFeeding.clientId === cid
    let queueId = null
    let albumCid = null
    for (const q of this.seqQueues || []) {
      const idx = q.items.findIndex((it) => it.clientId === cid)
      if (idx >= 0) {
        queueId = q.queueId
        albumCid = q.items[idx].albumCid
        this.forgetStored(q.items[idx])
        q.items.splice(idx, 1)
      }
    }
    this.seqQueues = (this.seqQueues || []).filter((q) => q.items.length)
    this.fadeTile(tile)
    if (feeding) {
      this.pushEvent("seq_reset", {})
      this.seqFeeding = null
      this.pumpSeq()
    } else if (queueId) {
      this.pushEvent("seq_drop", { queue_id: queueId, kind: "media", album_cid: albumCid })
    }
  },
  // Smoothly remove one tile from the mosaic (the flex row reflows to fill the gap).
  fadeTile(tile) {
    if (!tile) return
    tile.classList.add("ed-tile--out")
    setTimeout(() => tile.remove(), 160)
  },
  // Stall watchdog for the CURRENT sequential item (one at a time, so no batch/sibling fail
  // like the concurrent armStall). If it goes 90s with no progress: fade a stalled album
  // photo (tile) / mark a stalled file failed, tell the server to abort + drop it, remove it
  // from the client queue, and pump the next — the batch keeps going. Re-armed by seq_progress.
  armSeqStall(node) {
    // A thread send (phase F trim) has no optimistic node — arm a hook-level watchdog so a
    // stalled item still frees the slot + pumps the next (there's no tile/card to fade). The
    // node path fades the tile / marks the card failed on the right element. onSeqDone clears
    // the hook-level timer so a finished item's watchdog can't fire spuriously.
    if (!node) {
      const feeding = this.seqFeeding
      if (this._seqStall) clearTimeout(this._seqStall)
      this._seqStall = setTimeout(() => {
        this._seqStall = null
        this.pushEvent("seq_reset", {})
        if (feeding) this.dropSeqFeedingFromQueue(feeding)
        this.seqFeeding = null
        this.pumpSeq()
      }, 90000)
      return
    }
    if (node._stall) clearTimeout(node._stall)
    node._stall = setTimeout(() => {
      if (!node.isConnected) return
      const feeding = this.seqFeeding
      if (node.dataset.itemCid) this.fadeTile(node)
      else this.markUploadFailed(node)
      this.pushEvent("seq_reset", {})
      if (feeding) this.dropSeqFeedingFromQueue(feeding)
      this.seqFeeding = null
      this.pumpSeq()
    }, 90000)
  },
  // Remove the in-flight item from the client queue on stall/abort — just that item (a file,
  // or one album photo; the album continues with the rest).
  dropSeqFeedingFromQueue(feeding) {
    for (const q of this.seqQueues || []) {
      const idx = q.items.findIndex((it) => it.clientId === feeding.clientId)
      if (idx >= 0) {
        this.forgetStored(q.items[idx])
        q.items.splice(idx, 1)
      }
    }
    this.seqQueues = (this.seqQueues || []).filter((q) => q.items.length)
  },
  // Stamp the send's server-minted group_id onto its optimistic file rows, then fuse them
  // into the merged bubble so the upload happens INSIDE the formed fixed-width bubble (not
  // separate cards that glue together at the end).
  stampGroup(fileCids, groupId) {
    ;(fileCids || []).forEach((cid) => {
      const row = this.pending?.querySelector(`[data-client-id="${cid}"]`)
      if (row) row.dataset.groupId = groupId
    })
    this.reGroupOptimistic(groupId)
  },
  // Optimistic mirror of the server's merged-bubble render (mark_group_pos): apply the
  // fixed-width + fused-seam classes to a group's optimistic rows still in #pending, so an
  // in-flight send already looks like one bubble. Re-run whenever the set changes (a twin
  // swaps out on completion, via the riser's ed:regroup event).
  reGroupOptimistic(groupId) {
    if (!groupId || !this.pending) return
    const rows = [...this.pending.querySelectorAll(`.ed-msg[data-group-id="${groupId}"]`)]
    const n = rows.length
    // If real rows of this group already landed in #messages, they've OPENED the merged
    // bubble (:first / :middle, kept off :last while in-flight) — so the optimistic tail just
    // CONTINUES it (all :middle, the very last :last). Only when no real row exists yet does
    // the optimistic set own the whole bubble (first…last).
    const stream = document.getElementById("messages")
    const hasReal = !!(stream && stream.querySelector(`.ed-msg[data-group-id="${groupId}"]`))
    rows.forEach((row, i) => {
      // forEach only runs for n ≥ 1. With real rows present the tail just continues them
      // (:mid, the very last :last); otherwise the optimistic set owns the bubble (first…last,
      // or nil for a lone row).
      const pos = hasReal
        ? i === n - 1 ? "last" : "mid"
        : n === 1 ? null : i === 0 ? "first" : i === n - 1 ? "last" : "mid"
      const bubble = row.querySelector(".ed-bubble")
      row.classList.toggle("ed-msg--grp-cont", pos === "mid" || pos === "last")
      if (!bubble) return
      bubble.classList.toggle("ed-bubble--grp", pos != null)
      bubble.classList.toggle("ed-bubble--grp-first", pos === "first")
      bubble.classList.toggle("ed-bubble--grp-mid", pos === "mid")
      bubble.classList.toggle("ed-bubble--grp-last", pos === "last")
      // Time+ticks show once, on the last/solo row — hide the meta on first/middle (mirrors
      // the server render's `meta on :last only`).
      const cap = bubble.querySelector(".ed-bubble__cap")
      if (cap) cap.style.display = pos === "first" || pos === "mid" ? "none" : ""
    })
  },
  // The last flat row to compare against for the compact rule: a queued
  // optimistic node wins (rapid double-send), else the last streamed
  // message. Returns null in an empty room (first message — full row).
  lastFlatRow() {
    // Compare against the SEND's pane (#348): a thread build reads #thread-pending /
    // #thread-replies, the main build #pending-messages / #messages.
    const pend = (this._sendTarget && this._sendTarget.pending) || this.pending
    if (pend && pend.lastElementChild) {
      return pend.lastElementChild
    }
    const sel = this._sendTarget ? "#thread-replies .ed-flat" : "#messages .ed-flat"
    const rows = document.querySelectorAll(sel)
    return rows[rows.length - 1] || null
  },
  markFailed(clientId, body) {
    let node = this.findNode(clientId)
    // Rooms/groups draw no optimistic node on the happy path (#130/#142), so a
    // rejected send has nothing to mark — materialize it now (faded), then flag
    // it failed. Media nacks drop their node (push_media_failed), so this only
    // fires for text nacks.
    if (!node && body != null) {
      this.addOptimistic(clientId, body)
      node = this.pending.querySelector(`[data-client-id="${clientId}"]`)
    }
    if (!node) return
    // Tag the failed node with its conversation (#380/R064) so a chat switch HIDES it (like
    // a #144 media node) instead of the blind-remove that untagged text nodes get in
    // updated() — otherwise the ●!/Resend affordance for an undelivered message silently
    // vanishes on switch-away-and-back. Resend/flush are bound to this.convId, so re-sending
    // only fires in its own chat.
    node.dataset.convId = this.convId
    node.style.opacity = "1"
    node.classList.add("ed-msg-failed")
    if (body != null) node.dataset.body = body
    // Swap the status slot (clock, if any) for a tappable red ●! that opens a
    // resend/delete menu (#142). Bubble: in .ed-bubble__meta; flat row: a
    // trailing affordance on the row itself.
    const meta = node.querySelector(".ed-bubble__meta")
    const host = meta || node
    host.querySelectorAll(".ed-msg-failed__bang").forEach((b) => b.remove())
    if (meta) {
      // Drop the "sending" clock span (the inline-flex after <time>).
      meta.querySelectorAll(":scope > .inline-flex").forEach((s) => s.remove())
    }
    const bang = document.createElement("button")
    bang.type = "button"
    bang.className = "ed-msg-failed__bang"
    bang.setAttribute("aria-label", this.el.dataset.failed || "Not delivered")
    bang.innerHTML = window.edIcon("hero-exclamation-circle-micro", "size-3.5")
    bang.addEventListener("click", (e) => {
      e.preventDefault()
      e.stopPropagation()
      this.openFailMenu(node)
    })
    host.appendChild(bang)
  },
  failedNodes() {
    return [...this.pending.querySelectorAll(".ed-msg-failed")]
  },
  // Re-send one failed node (same client_id → idempotent): drop it, redraw the
  // optimistic node, re-queue, flush.
  resendNode(node) {
    const clientId = node.dataset.clientId
    const body = node.dataset.body || ""
    node.remove()
    if (!body) return
    this.addOptimistic(clientId, body)
    this.queue.push({ clientId, body, sent: false })
  },
  openFailMenu(node) {
    this.closeFailMenu()
    const d = this.el.dataset
    const failed = this.failedNodes()
    const menu = document.createElement("div")
    menu.className = "ed-menu ed-fail-menu"
    menu.setAttribute("role", "menu")
    const item = (label, onClick, danger) => {
      const b = document.createElement("button")
      b.type = "button"
      b.className = "ed-menu__item" + (danger ? " ed-menu__item--danger" : "")
      b.setAttribute("role", "menuitem")
      b.textContent = label
      b.addEventListener("click", () => { this.closeFailMenu(); onClick() })
      menu.appendChild(b)
    }
    item(d.resend || "Resend", () => { this.resendNode(node); this.flush() })
    // Batch: offer to re-send every failed message at once.
    if (failed.length > 1) {
      const label = (d.resendMany || "Resend {count} messages")
        .replace("{count}", failed.length)
      item(label, () => { failed.forEach((n) => this.resendNode(n)); this.flush() })
    }
    item(d.delete || "Delete", () => node.remove(), true)
    document.body.appendChild(menu)
    // Anchor to the ●!: the marker sits at the message's trailing (right) edge,
    // so right-align the menu under it and grow from that corner; flip above the
    // ! when there isn't room below. Clamped to the viewport.
    const r = (node.querySelector(".ed-msg-failed__bang") || node).getBoundingClientRect()
    const mw = menu.offsetWidth, mh = menu.offsetHeight
    const left = Math.max(8, Math.min(r.right - mw, window.innerWidth - mw - 8))
    const fitsBelow = r.bottom + 4 + mh <= window.innerHeight - 8
    const top = fitsBelow ? r.bottom + 4 : Math.max(8, r.top - mh - 4)
    menu.style.left = left + "px"
    menu.style.top = top + "px"
    menu.style.transformOrigin = fitsBelow ? "top right" : "bottom right"
    this.failMenu = menu
    this.onFailDoc = (e) => { if (!menu.contains(e.target)) this.closeFailMenu() }
    this.onFailKey = (e) => { if (e.key === "Escape") this.closeFailMenu() }
    // Land focus on the first action (keyboard a11y), like .ContextMenu.
    menu.querySelector("[role=menuitem]")?.focus({ preventScroll: true })
    setTimeout(() => {
      document.addEventListener("click", this.onFailDoc)
      document.addEventListener("keydown", this.onFailKey)
      document.addEventListener("scroll", this.onFailDoc, { capture: true, passive: true })
    }, 0)
  },
  closeFailMenu() {
    if (!this.failMenu) return
    this.failMenu.remove()
    this.failMenu = null
    document.removeEventListener("click", this.onFailDoc)
    document.removeEventListener("keydown", this.onFailKey)
    document.removeEventListener("scroll", this.onFailDoc, { capture: true })
  },
}
