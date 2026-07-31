defmodule EdenWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: EdenWeb.Gettext

  # For the icon sprite's path (#511): static files go through the digest, so the reference has
  # to be built by a verified route rather than written as a literal.
  use Phoenix.VerifiedRoutes,
    endpoint: EdenWeb.Endpoint,
    router: EdenWeb.Router,
    statics: EdenWeb.static_paths()

  alias Phoenix.LiveView.JS

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <svg class={["ed-icon", @class]} aria-hidden="true" focusable="false">
      <use href={~p"/images/icons.svg" <> "##{@name}"} />
    </svg>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(EdenWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(EdenWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Brand-styled flash (info/error) for auth pages that render outside the app
  layout. Renders nothing when there is no flash.
  """
  attr :flash, :map, required: true

  def ed_flash(assigns) do
    ~H"""
    <div class="space-y-2 mb-4 empty:hidden">
      <div
        :if={msg = Phoenix.Flash.get(@flash, :error)}
        id="flash-error"
        phx-hook=".FlashAutoHide"
        data-autohide="false"
        class="ed-toast ed-toast--error pointer-events-auto"
        role="alert"
      >
        <span class="ed-toast__bar"></span>
        <span class="flex-1">{msg}</span>
        <button
          type="button"
          class="ed-toast__close"
          data-flash-close
          phx-click={JS.push("lv:clear-flash", value: %{key: "error"}) |> JS.hide(to: "#flash-error")}
          aria-label={gettext("Dismiss")}
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </div>
      <div
        :if={msg = Phoenix.Flash.get(@flash, :info)}
        id="flash-info"
        phx-hook=".FlashAutoHide"
        data-autohide="true"
        class="ed-toast ed-toast--info pointer-events-auto"
        role="status"
      >
        <span class="ed-toast__bar"></span>
        <span class="flex-1">{msg}</span>
        <button
          type="button"
          class="ed-toast__close"
          data-flash-close
          phx-click={JS.push("lv:clear-flash", value: %{key: "info"}) |> JS.hide(to: "#flash-info")}
          aria-label={gettext("Dismiss")}
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".FlashAutoHide">
        // Info flashes self-dismiss after a few seconds; errors stay until dismissed.
        export default {
          mounted() { this.arm() },
          // A second info flash reuses this same DOM node (morphdom patches the text in
          // place, so mounted() doesn't re-run) — re-arm on the patch or the first flash's
          // timer would dismiss the new one early.
          updated() { this.arm() },
          destroyed() { clearTimeout(this._t) },
          arm() {
            clearTimeout(this._t)
            if (this.el.dataset.autohide !== "true") return
            this._t = setTimeout(() => {
              const x = this.el.querySelector("[data-flash-close]")
              x && x.click()
            }, 5000)
          }
        }
      </script>
    </div>
    """
  end

  @doc """
  Brand-styled labeled text input (eden design system) with field errors. Shared
  by auth forms so login and invite render identically. Password inputs never
  echo their value back to the client.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"

  attr :rest, :global, include: ~w(autocomplete autofocus required maxlength placeholder
                autocapitalize autocorrect spellcheck)

  def ed_field(assigns) do
    ~H"""
    <label class="block space-y-1.5">
      <span style="font-size:0.8125rem; color: var(--ed-muted);">
        {@label}<span
          :if={@rest[:required]}
          style="color: var(--ed-danger-strong);"
          aria-hidden="true"
        > *</span>
      </span>
      <input
        class="ed-input"
        type={@type}
        name={@field.name}
        id={@field.id}
        value={@type != "password" && Phoenix.HTML.Form.normalize_value(@type, @field.value)}
        {@rest}
      />
      <.ed_field_errors field={@field} />
    </label>
    """
  end

  # Field errors, shown only once the person has actually typed in THAT input
  # (used_input?, like the stock input/1) — otherwise "does not match the password"
  # flashes under the confirmation while they're still on the first field (#306 review).
  # `--ed-danger-strong` is the as-text danger tier: plain `--ed-danger` is a fill color
  # and only hits ~3.5:1 on the dark background (#265).
  attr :field, Phoenix.HTML.FormField, required: true

  defp ed_field_errors(assigns) do
    errors = if Phoenix.Component.used_input?(assigns.field), do: assigns.field.errors, else: []
    assigns = assign(assigns, :errors, errors)

    ~H"""
    <span
      :for={msg <- Enum.map(@errors, &translate_error/1)}
      style="color: var(--ed-danger-strong); font-size:0.75rem;"
    >
      {msg}
    </span>
    """
  end

  @doc """
  Password field with a show/hide (eye) toggle (#306). Same look + error rendering as
  `ed_field`, but never echoes the value back and reveals what you typed on demand — used
  by the registration form. The `.PasswordReveal` colocated hook flips the input `type`.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :rest, :global, include: ~w(autocomplete autofocus required maxlength placeholder)

  def ed_password_field(assigns) do
    ~H"""
    <label class="block space-y-1.5" phx-hook=".PasswordReveal" id={"#{@field.id}-wrap"}>
      <span style="font-size:0.8125rem; color: var(--ed-muted);">
        {@label}<span
          :if={@rest[:required]}
          style="color: var(--ed-danger-strong);"
          aria-hidden="true"
        > *</span>
      </span>
      <div class="relative">
        <input
          class="ed-input pr-10"
          type="password"
          name={@field.name}
          id={@field.id}
          data-reveal-input
          {@rest}
        />
        <button
          type="button"
          data-reveal-toggle
          aria-pressed="false"
          aria-label={gettext("Show password")}
          data-show-label={gettext("Show password")}
          data-hide-label={gettext("Hide password")}
          class="ed-btn--affix absolute right-1 top-1/2 -translate-y-1/2"
        >
          <span data-reveal-eye><.icon name="hero-eye" class="size-4" /></span>
          <span data-reveal-eye-off class="hidden">
            <.icon name="hero-eye-slash" class="size-4" />
          </span>
        </button>
      </div>
      <.ed_field_errors field={@field} />
      <script :type={Phoenix.LiveView.ColocatedHook} name=".PasswordReveal">
        // Toggle a password input between hidden and visible, swapping the eye icon
        // and keeping aria-pressed / aria-label in sync for screen readers.
        //
        // The toggle state is CLIENT-owned: the server always renders the masked
        // default, and any LiveView patch (e.g. the form's phx-change validate on
        // every keystroke) morphs type/aria/classes back — so the state lives on
        // the hook and updated() re-applies it after each patch (#306 review; the
        // focused-input carve-out only preserves `value`, not `type`).
        export default {
          mounted() {
            this.showing = false
            this._onClick = () => {
              this.showing = !this.showing
              this.sync()
            }
            const btn = this.el.querySelector("[data-reveal-toggle]")
            btn && btn.addEventListener("click", this._onClick)
          },
          updated() { this.sync() },
          sync() {
            const input = this.el.querySelector("[data-reveal-input]")
            const btn = this.el.querySelector("[data-reveal-toggle]")
            if (!input || !btn) return
            const show = this.showing
            input.type = show ? "text" : "password"
            btn.setAttribute("aria-pressed", String(show))
            // Labels come from data-* so they honour the server-side gettext locale.
            btn.setAttribute("aria-label", show ? btn.dataset.hideLabel : btn.dataset.showLabel)
            const eye = this.el.querySelector("[data-reveal-eye]")
            const eyeOff = this.el.querySelector("[data-reveal-eye-off]")
            eye && eye.classList.toggle("hidden", show)
            eyeOff && eyeOff.classList.toggle("hidden", !show)
          },
          destroyed() {
            const btn = this.el.querySelector("[data-reveal-toggle]")
            btn && this._onClick && btn.removeEventListener("click", this._onClick)
          }
        }
      </script>
    </label>
    """
  end
end
