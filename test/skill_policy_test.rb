# frozen_string_literal: true

require 'minitest/autorun'

class SkillPolicyTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_review_routes_to_retained_member_or_catalog_default
    skill = File.read(File.join(ROOT, 'skills/mandatory-change-review/SKILL.md'))

    assert_match(/eligible retained member whose saved purpose\s+is `review`.*lowest numeric member index/m, skill)
    assert_match(/Legacy `reviewerN` members without a saved purpose\s+also qualify/, skill)
    assert_match(/saved model and reasoning\s+effort exactly/, skill)
    assert_match(/omitting `--model` and `--effort`/, skill)
    assert_match(/review-purpose role in the installed catalog's\s+default development team/, skill)
    assert_match(/including a solo session/, skill)
    assert_match(/does not add a member or change the roster/, skill)
  end

  def test_final_review_requires_complete_history_and_explicit_conclusions
    skill = File.read(File.join(ROOT, 'skills/mandatory-change-review/SKILL.md'))
    general = File.read(File.join(ROOT, 'skills/mandatory-change-review/references/general-review.md'))

    assert_match(/Before claiming an unmerged feature branch ready, arrange a final review/, skill)
    assert_match(/complete base-to-head commit series and final diff/, skill)
    assert_match(/Earlier incremental reviews do not\s+complete this final gate/, skill)
    assert_match(/complete base-to-head commit list and\s+final diff/, skill)
    assert_match(/Explicitly conclude whether obsolete\s+unmerged approaches remain/, skill)
    assert_match(/If the packet lacks the complete\s+series or migration inventory and provenance, request them/, skill)
    assert_match(/complete base-to-head commit list with\s+the final diff/, general)
    assert_match(/explicitly conclude that no obsolete branch history remains/, general)
    assert_match(/narrow fix.*inspect and verify that fix directly/m, skill)
  end

  def test_final_review_checks_migration_provenance_and_empty_inventory
    skill = File.read(File.join(ROOT, 'skills/mandatory-change-review/SKILL.md'))
    risk = File.read(File.join(ROOT, 'skills/mandatory-change-review/references/risk-review.md'))

    assert_match(/each migration version was merged, released, deployed, or\s+externally consumed/, skill)
    assert_match(/explicitly state when there are no migrations/, skill)
    assert_match(/state "no\s+migrations" when the inventory is empty/, skill)
    assert_match(/merge, release, deployment, and external-use provenance/, risk)
    assert_match(/only upgrade an earlier, unapplied branch iteration/, risk)
    assert_match(/fresh schema load, bootstrap data, and upgrades\s+from deployed schemas separately/, risk)
    assert_match(/migration-lineage\s+conclusion, or "no migrations"/, risk)
  end

  def test_handoff_keeps_unapproved_feature_active
    skill = File.read(File.join(ROOT, 'skills/dev-session-handoff/SKILL.md'))

    assert_match(/ready, awaiting merge approval/, skill)
    assert_match(/Review, CI, deployment, or plan\s+acceptance does not supply that approval/, skill)
  end
end
