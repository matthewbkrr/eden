// Every LiveView hook the app registers (#510).
//
// They used to live as colocated <script> blocks inside chat_live.ex — 7921 of that file's 18692
// lines, which meant every one-line JS edit recompiled the LiveView (10.5s measured) and no
// linter or unit test could see any of it. Moved verbatim; the only change at each site is
// `phx-hook=".X"` becoming `phx-hook="X"`, since the name is now global rather than
// module-scoped.

import ContextMenu from "./ContextMenu"
import CopySelection from "./CopySelection"
import CopyUrl from "./CopyUrl"
import DateRail from "./DateRail"
import DropZone from "./DropZone"
import EmojiPicker from "./EmojiPicker"
import FocusTrap from "./FocusTrap"
import FolderTabs from "./FolderTabs"
import ForwardCarry from "./ForwardCarry"
import GalleryMonths from "./GalleryMonths"
import GalleryTabs from "./GalleryTabs"
import IdleTracker from "./IdleTracker"
import ImgPreview from "./ImgPreview"
import InstantNav from "./InstantNav"
import LastSeen from "./LastSeen"
import Lightbox from "./Lightbox"
import LocalTime from "./LocalTime"
import LocalTimes from "./LocalTimes"
import NewConvGate from "./NewConvGate"
import NotifyPerm from "./NotifyPerm"
import PasteUpload from "./PasteUpload"
import Popover from "./Popover"
import PresenceDots from "./PresenceDots"
import ReactionGrid from "./ReactionGrid"
import RoomSortable from "./RoomSortable"
import ScrollBottom from "./ScrollBottom"
import SearchBox from "./SearchBox"
import SelectAllOnClick from "./SelectAllOnClick"
import SelectOnFocus from "./SelectOnFocus"
import SelectSync from "./SelectSync"
import SendQueue from "./SendQueue"
import SidebarReorder from "./SidebarReorder"
import Sortable from "./Sortable"
import SoundPreview from "./SoundPreview"
import StreamVideo from "./StreamVideo"
import TabBadge from "./TabBadge"
import ThemeSegA11y from "./ThemeSegA11y"
import ThreadSendQueue from "./ThreadSendQueue"
import VideoExpand from "./VideoExpand"
import VideoPreview from "./VideoPreview"

export const edenHooks = {
  ContextMenu,
  CopySelection,
  CopyUrl,
  DateRail,
  DropZone,
  EmojiPicker,
  FocusTrap,
  FolderTabs,
  ForwardCarry,
  GalleryMonths,
  GalleryTabs,
  IdleTracker,
  ImgPreview,
  InstantNav,
  LastSeen,
  Lightbox,
  LocalTime,
  LocalTimes,
  NewConvGate,
  NotifyPerm,
  PasteUpload,
  Popover,
  PresenceDots,
  ReactionGrid,
  RoomSortable,
  ScrollBottom,
  SearchBox,
  SelectAllOnClick,
  SelectOnFocus,
  SelectSync,
  SendQueue,
  SidebarReorder,
  Sortable,
  SoundPreview,
  StreamVideo,
  TabBadge,
  ThemeSegA11y,
  ThreadSendQueue,
  VideoExpand,
  VideoPreview,
}
