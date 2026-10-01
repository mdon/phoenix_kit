defmodule Mix.Tasks.PhoenixKit.DoctorVariantPipelineTest do
  @moduledoc """
  The doctor's "Image Sizes From an Older Pipeline" check: it warns about
  sizes made before the current rendering rules and says how to remake them,
  but never remakes anything itself — on a large library that is the host's
  call to schedule.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.PhoenixKit.Doctor
  alias PhoenixKit.Modules.Storage.{Dimension, VariantSets}

  test "nothing old: pass" do
    assert {:pass, _} = Doctor.pipeline_verdict(0)
  end

  test "old sizes: a warning naming the manual remake and its cost" do
    assert {:warn, message} = Doctor.pipeline_verdict(42)
    assert message =~ "42 image sizes"
    assert message =~ "VariantSets.remake_all()"
    assert message =~ "EVERY size of EVERY file"
  end

  test "the count is capped, and says so" do
    assert {:warn, message} = Doctor.pipeline_verdict(10_000)
    assert message =~ "10000+ image sizes"
  end

  test "the hashes looked for are pipeline-1's, never the current ones" do
    rows = [[800, 600, 85, "jpg", true, ["webp"]], [200, 200, 80, nil, false, []]]
    hashes = Doctor.legacy_hashes(rows)

    d1 = %Dimension{width: 800, height: 600, quality: 85, maintain_aspect_ratio: true}
    d2 = %Dimension{width: 200, height: 200, quality: 80, maintain_aspect_ratio: false}

    assert VariantSets.legacy_spec_hash(d1, "jpg") in hashes
    assert VariantSets.legacy_spec_hash(d1, "webp") in hashes
    assert VariantSets.legacy_spec_hash(d2, nil) in hashes
    assert length(hashes) == 3

    for {d, f} <- [{d1, "jpg"}, {d1, "webp"}, {d2, nil}] do
      refute VariantSets.spec_hash(d, f) in hashes, "a current size would be counted as old"
    end
  end
end
