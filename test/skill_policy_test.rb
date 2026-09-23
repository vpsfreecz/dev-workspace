# frozen_string_literal: true

require 'minitest/autorun'

class SkillPolicyTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_review_routes_to_retained_member_or_catalog_default
    skill = File.read(File.join(ROOT, 'skills/mandatory-change-review/SKILL.md'))

    assert_match(/eligible retained `reviewerN`.*lowest index/m, skill)
    assert_match(/saved model and reasoning\s+effort exactly/, skill)
    assert_match(/omitting `--model` and `--effort`/, skill)
    assert_match(/installed catalog's default development reviewer/, skill)
    assert_match(/including a solo session/, skill)
    assert_match(/does not add a member or change the roster/, skill)
  end

  def test_handoff_keeps_unapproved_feature_active
    skill = File.read(File.join(ROOT, 'skills/dev-session-handoff/SKILL.md'))

    assert_match(/ready, awaiting merge approval/, skill)
    assert_match(/Review, CI, deployment, or plan\s+acceptance does not supply that approval/, skill)
  end
end
