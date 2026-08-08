// Every LiveView hook the app registers (#510).
//
// They used to live as colocated <script> blocks inside chat_live.ex — 7921 of that file's 18692
// lines, which meant every one-line JS edit recompiled the LiveView (10.5s measured) and no
// linter or unit test could see any of it. Moved verbatim; the only change at each site is
// `phx-hook=".X"` becoming `phx-hook="X"`, since the name is now global rather than
// module-scoped.
//
// Only the hooks below are in the boot bundle (#511). They earn the place by doing their work at
// mount: painting a timestamp, placing an indicator, positioning the feed, taking over a tap
// before the first one can land. Everything else answers an interaction and arrives in the second
// bundle — see `deferred.js`.

import { armDeferredHooks, deferredHooks } from "./deferred"
import FolderTabs from "./FolderTabs"
import ForwardCarry from "./ForwardCarry"
import InstantNav from "./InstantNav"
import LastSeen from "./LastSeen"
import LocalTime from "./LocalTime"
import LocalTimes from "./LocalTimes"
import PresenceDots from "./PresenceDots"
import ScrollBottom from "./ScrollBottom"
import StreamVideo from "./StreamVideo"
import TabBadge from "./TabBadge"

export { armDeferredHooks }

export const edenHooks = {
  ...deferredHooks(),
  FolderTabs,
  ForwardCarry,
  InstantNav,
  LastSeen,
  LocalTime,
  LocalTimes,
  PresenceDots,
  ScrollBottom,
  StreamVideo,
  TabBadge,
}
