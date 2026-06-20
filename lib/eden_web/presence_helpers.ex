defmodule EdenWeb.PresenceHelpers do
  @moduledoc """
  Single source of truth for presence-status *presentation* (#102): the picker
  options plus the effective-status → label/color helpers, shared by the rail
  picker, Settings, and the chat surfaces. The status *values* themselves live in
  `Eden.Accounts.User.presence_statuses/0` (domain); their effective mapping lives
  in `EdenWeb.Presence.manual_to_effective/1`.
  """
  use Gettext, backend: EdenWeb.Gettext

  @doc """
  Picker options as `{value, label, short_label, color_var}`: `value` is the
  manual status; `label` is the full menu label; `short_label` fits a segmented
  control; `color_var` is the swatch color.
  """
  def status_options do
    [
      {"auto", gettext("Active"), gettext("Active"), "--ed-online"},
      {"away", gettext("Away"), gettext("Away"), "--ed-away"},
      {"dnd", gettext("Do Not Disturb"), gettext("DND"), "--ed-dnd"},
      {"invisible", gettext("Invisible"), gettext("Invisible"), "--ed-muted"}
    ]
  end

  @doc "Human label for an effective presence status (nil = offline)."
  def status_label("online"), do: gettext("online")
  def status_label("away"), do: gettext("away")
  def status_label("dnd"), do: gettext("do not disturb")
  def status_label(_offline), do: gettext("offline")

  @doc "CSS color variable for an effective presence status (nil = offline)."
  def status_color_var("online"), do: "--ed-online"
  def status_color_var("away"), do: "--ed-away"
  def status_color_var("dnd"), do: "--ed-dnd"
  def status_color_var(_offline), do: "--ed-muted"

  @doc "Dot modifier class for the rail self-indicator, by the user's MANUAL status."
  def me_dot_class("away"), do: "ed-avatar__dot--away"
  def me_dot_class("dnd"), do: "ed-avatar__dot--dnd"
  def me_dot_class("invisible"), do: "ed-avatar__dot--invisible"
  def me_dot_class(_auto), do: nil
end
