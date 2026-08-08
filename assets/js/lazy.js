// The second bundle (#511): every hook that answers an interaction rather than the first paint.
//
// Fetched by `hooks/deferred.js` after boot — at idle or on the first gesture — and handed to the
// placeholders it registered. Kept as a plain global rather than an ES module so both bundles can
// come out of the one esbuild profile; the name is internal, read in exactly one place.
//
// Adding a hook here means adding its name to `DEFERRED` in `hooks/deferred.js`. Forgetting one
// half fails `zz-lazy-hooks.spec.js`, not the browser.

import ContextMenu from "./hooks/ContextMenu"
import CopySelection from "./hooks/CopySelection"
import CopyUrl from "./hooks/CopyUrl"
import DateRail from "./hooks/DateRail"
import DropZone from "./hooks/DropZone"
import EmojiPicker from "./hooks/EmojiPicker"
import GalleryMonths from "./hooks/GalleryMonths"
import GalleryTabs from "./hooks/GalleryTabs"
import IdleTracker from "./hooks/IdleTracker"
import ImgPreview from "./hooks/ImgPreview"
import Lightbox from "./hooks/Lightbox"
import Mentions from "./hooks/Mentions"
import NewConvGate from "./hooks/NewConvGate"
import NotifyPerm from "./hooks/NotifyPerm"
import PasteUpload from "./hooks/PasteUpload"
import Popover from "./hooks/Popover"
import ReactionGrid from "./hooks/ReactionGrid"
import RoomSortable from "./hooks/RoomSortable"
import SearchBox from "./hooks/SearchBox"
import SelectAllOnClick from "./hooks/SelectAllOnClick"
import SelectOnFocus from "./hooks/SelectOnFocus"
import SelectSync from "./hooks/SelectSync"
import SendQueue from "./hooks/SendQueue"
import SidebarReorder from "./hooks/SidebarReorder"
import Sortable from "./hooks/Sortable"
import SoundPreview from "./hooks/SoundPreview"
import ThemeSegA11y from "./hooks/ThemeSegA11y"
import ThreadSendQueue from "./hooks/ThreadSendQueue"
import VideoExpand from "./hooks/VideoExpand"
import VideoPreview from "./hooks/VideoPreview"

window.__edenLazyHooks = {
  ContextMenu,
  CopySelection,
  CopyUrl,
  DateRail,
  DropZone,
  EmojiPicker,
  GalleryMonths,
  GalleryTabs,
  IdleTracker,
  ImgPreview,
  Lightbox,
  Mentions,
  NewConvGate,
  NotifyPerm,
  PasteUpload,
  Popover,
  ReactionGrid,
  RoomSortable,
  SearchBox,
  SelectAllOnClick,
  SelectOnFocus,
  SelectSync,
  SendQueue,
  SidebarReorder,
  Sortable,
  SoundPreview,
  ThemeSegA11y,
  ThreadSendQueue,
  VideoExpand,
  VideoPreview,
}
