defmodule PhoenixKit.Install.JsIntegrationTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Install.JsIntegration

  # The pure app.js transform behind the installer's viewport-param step. Every
  # case here came out of adversarial review — regex surgery on arbitrary host
  # code must corrupt NOTHING: when in doubt it returns :manual (notice) rather
  # than a wrong rewrite.
  describe "inject_viewport_param/1" do
    test "rewrites the standard phx.new shape into a closure" do
      content = """
      const liveSocket = new LiveSocket("/live", Socket, {
        longPollFallbackMs: 2500,
        params: {_csrf_token: csrfToken},
        hooks: {...window.PhoenixKitHooks},
      })
      """

      assert {:ok, updated} = JsIntegration.inject_viewport_param(content)

      assert updated =~
               "params: () => ({_csrf_token: csrfToken, viewport_width: window.innerWidth})"

      # …and the second run is a no-op.
      assert JsIntegration.inject_viewport_param(updated) == :already
    end

    test "an empty params object gets no stray comma" do
      assert {:ok, updated} =
               JsIntegration.inject_viewport_param(~s|new LiveSocket("/l", Socket, {params: {}})|)

      assert updated =~ "params: () => ({viewport_width: window.innerWidth})"
    end

    test "multibyte UTF-8 before the call does not corrupt the reassembly" do
      content = """
      // © Mäx Dön — app.js …
      const liveSocket = new LiveSocket("/live", Socket, {
        params: {_csrf_token: csrfToken},
      })
      """

      assert {:ok, updated} = JsIntegration.inject_viewport_param(content)
      assert updated =~ "// © Mäx Dön"
      assert updated =~ "params: () => ({_csrf_token: csrfToken, viewport_width:"
    end

    test "does NOT rewrite a nested params inside a hook body" do
      content = """
      const liveSocket = new LiveSocket("/live", Socket, {
        hooks: {
          Loader: { mounted(){ this.pushEvent("load", {params: {page: 1}}) } }
        },
        params: {_csrf_token: csrfToken}
      })
      """

      assert {:ok, updated} = JsIntegration.inject_viewport_param(content)
      # Hook payload untouched; the real LiveSocket params patched.
      assert updated =~ ~s|this.pushEvent("load", {params: {page: 1}})|
      assert updated =~ "params: () => ({_csrf_token: csrfToken, viewport_width:"
    end

    test "a commented-out example call does not anchor the patch" do
      content = """
      // Example: new LiveSocket("/live", Socket, { params: {_csrf_token: csrfToken} })
      const liveSocket = new LiveSocket("/live", Socket, {
        params: {_csrf_token: csrfToken}
      })
      """

      assert {:ok, updated} = JsIntegration.inject_viewport_param(content)
      # The comment keeps its plain object; the real call gets the closure.
      assert updated =~
               ~s|// Example: new LiveSocket("/live", Socket, { params: {_csrf_token: csrfToken} })|

      assert updated =~ "params: () => ({_csrf_token: csrfToken, viewport_width:"
    end

    test "an earlier plain Socket's params is never touched" do
      content = """
      const userSocket = new Socket("/socket", {params: {token: userToken}})
      const liveSocket = new LiveSocket("/live", Socket, {
        params: {_csrf_token: csrfToken},
      })
      """

      assert {:ok, updated} = JsIntegration.inject_viewport_param(content)
      assert updated =~ ~s|new Socket("/socket", {params: {token: userToken}})|
      assert updated =~ "params: () => ({_csrf_token: csrfToken, viewport_width:"
    end

    test "braces inside string literals cannot fake depth at a nested site" do
      content = """
      const liveSocket = new LiveSocket("/live", Socket, {
        metadata: {
          click: (e, el) => {
            const close = "}}}";
            return {params: {source: "click"}}
          }
        },
        params: {_csrf_token: csrfToken}
      })
      """

      assert {:ok, updated} = JsIntegration.inject_viewport_param(content)
      # The nested return payload stays byte-identical; only the real one moves.
      assert updated =~ ~s|return {params: {source: "click"}}|
      assert updated =~ "params: () => ({_csrf_token: csrfToken, viewport_width:"
    end

    test "a BLOCK-commented example call does not anchor the patch" do
      content = """
      /*
      Example:
      new LiveSocket("/live", Socket, {
        params: {_csrf_token: fake}
      })
      */
      const liveSocket = new LiveSocket("/live", Socket, {
        params: {_csrf_token: csrfToken}
      })
      """

      assert {:ok, updated} = JsIntegration.inject_viewport_param(content)
      assert updated =~ "params: {_csrf_token: fake}"
      assert updated =~ "params: () => ({_csrf_token: csrfToken, viewport_width:"
    end

    test "a params object containing comments is refused (manual notice)" do
      content = """
      const liveSocket = new LiveSocket("/live", Socket, {
        params: {
          _csrf_token: csrfToken, // standard csrf
        },
      })
      """

      assert JsIntegration.inject_viewport_param(content) == :manual
    end

    test "params already a closure is refused rather than guessed at" do
      assert JsIntegration.inject_viewport_param(
               ~s|new LiveSocket("/live", Socket, {params: () => ({_csrf_token: t})})|
             ) == :manual
    end

    test "no LiveSocket call at all is refused" do
      assert JsIntegration.inject_viewport_param(~s|const x = {params: {a: 1}}|) == :manual
    end

    test "a prose mention of viewport_width does not fake idempotency" do
      content = """
      // TODO: add viewport_width someday
      const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: t}})
      """

      assert {:ok, updated} = JsIntegration.inject_viewport_param(content)
      assert updated =~ "viewport_width: window.innerWidth"
    end

    test "the key form anywhere means already patched" do
      assert JsIntegration.inject_viewport_param(
               ~s|new LiveSocket("/l", Socket, {params: () => ({t: 1, viewport_width: window.innerWidth})})|
             ) == :already
    end
  end
end
