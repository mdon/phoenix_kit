defmodule PhoenixKitWeb.Components.Core.FormActions do
  @moduledoc """
  Form-footer action bar — Cancel link + Submit button, right-aligned.

  Replaces the repeated boilerplate:

      <div class="flex justify-end gap-3">
        <.link navigate={cancel_path} class="btn btn-ghost">Cancel</.link>
        <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">
          {submit_label}
        </button>
      </div>

  with a single component call.

  ## Attributes

  - `cancel_to` — Path the Cancel link navigates to. Required.
  - `submit_label` — Text on the submit button (e.g. `"Save"`, `"Create Endpoint"`).
    Required.
  - `submitting_label` — `phx-disable-with` text shown while the form is
    submitting. Defaults to `"Saving…"` (gettext-translated).
  - `submit_icon` — Optional Heroicon name rendered inside the submit
    button (e.g. `"hero-check"`).
  - `submit_class` — Class for the submit button. Default `"btn btn-primary"`.
  - `class` — Extra classes appended to the outer wrapper.

  ## Slots

  - `inner_block` — Optional extra controls rendered BEFORE Cancel + Submit
    (e.g. a secondary "Save and Return" button).

  ## Example

      <.form_actions
        cancel_to={Paths.endpoints()}
        submit_label={if @endpoint, do: gettext("Update"), else: gettext("Create")}
        submit_icon="hero-check"
      />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  attr :cancel_to, :string, required: true
  attr :submit_label, :string, required: true
  attr :submitting_label, :string, default: nil
  attr :submit_icon, :string, default: nil
  attr :submit_class, :string, default: "btn btn-primary"
  attr :class, :string, default: nil

  slot :inner_block

  def form_actions(assigns) do
    # `attr :submitting_label, default: nil` always assigns nil when the
    # consumer doesn't pass the attr, so `assign_new` won't fire. Use an
    # explicit `||` fallback to gettext'd default.
    assigns =
      assign(assigns, :submitting_label, assigns[:submitting_label] || gettext("Saving…"))

    ~H"""
    <div class={["flex justify-end gap-3", @class]}>
      {render_slot(@inner_block)}
      <.link navigate={@cancel_to} class="btn btn-ghost">
        {gettext("Cancel")}
      </.link>
      <button type="submit" class={@submit_class} phx-disable-with={@submitting_label}>
        <.icon :if={@submit_icon} name={@submit_icon} class="w-4 h-4 mr-2" />
        {@submit_label}
      </button>
    </div>
    """
  end
end
