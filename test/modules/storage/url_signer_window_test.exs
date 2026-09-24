defmodule PhoenixKit.Modules.Storage.URLSignerWindowTest do
  @moduledoc """
  The time-window tokens of private-library file URLs (V203), DB-less: the
  expiry is rounded up to a window and never less than a quarter of one
  away, the same URL comes back within a window, and the token shape can
  never be mistaken for the permanent 4-hex one.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.URLSigner

  @window 12 * 3600

  test "the expiry is the end of a window, at least a quarter window away" do
    for now <- [0, 1, @window - 1, @window, 3 * @window + 17, 1_790_000_000] do
      expiry = URLSigner.window_end(now, @window)

      assert rem(expiry, @window) == 0
      assert expiry - now >= div(@window, 4)
      assert expiry - now <= @window + div(@window, 4)
    end
  end

  test "one window gives one expiry, until its last quarter" do
    start = 100 * @window

    assert URLSigner.window_end(start, @window) ==
             URLSigner.window_end(start + div(@window, 2), @window)

    assert URLSigner.window_end(start + div(@window, 4) * 3, @window) ==
             URLSigner.window_end(start, @window) + @window
  end

  test "the shapes never overlap" do
    refute URLSigner.private_token?(URLSigner.generate_token("f", "original"))
    refute URLSigner.private_token?("abcd")
    refute URLSigner.private_token?(nil)
    assert URLSigner.private_token?("w1-x")
  end

  test "verify refuses anything that is not a window token" do
    assert URLSigner.verify_private_token("f", "original", "abcd", 0) == :invalid
    assert URLSigner.verify_private_token("f", "original", "wzz", 0) == :invalid
    assert URLSigner.verify_private_token("f", "original", "w!!-x", 0) == :invalid
  end
end
