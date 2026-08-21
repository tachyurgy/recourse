require "test_helper"

class ClassifierEvalTest < ActiveSupport::TestCase
  test "the fixture set is well formed" do
    cases = ClassifierEval.cases
    assert_operator cases.size, :>=, 25, "the labelled set has to be big enough to be worth reading"
    assert_equal cases.map(&:id).uniq.size, cases.size, "case ids must be unique"
    cases.each do |c|
      assert Reply::INTENTS.include?(c.expected), "#{c.id} has an unknown label #{c.expected}"
      assert c.body.present?, "#{c.id} has no body"
      assert c.note.present?, "#{c.id} has no note explaining why it is in the set"
    end
  end

  test "every intent is represented, including the ones that are cheap to ignore" do
    covered = ClassifierEval.cases.map(&:expected).uniq
    assert_equal Reply::INTENTS.sort, covered.sort,
                 "an eval set that skips a class cannot detect regressions in it"
  end

  test "the eval runs against the deterministic baseline and reports a real number" do
    e = ClassifierEval.new(force_rules: true).run

    assert_equal ClassifierEval.cases.size, e.total
    assert_operator e.accuracy, :>, 0.0
    assert_operator e.accuracy, :<, 100.0,
                    "a baseline that scores 100 means the set is too easy to be informative"
    assert_equal "rules", e.classifier_name
  end

  test "the baseline is deterministic" do
    a = ClassifierEval.new(force_rules: true).run.accuracy
    b = ClassifierEval.new(force_rules: true).run.accuracy
    assert_equal a, b
  end

  test "misses carry the context needed to act on them" do
    e = ClassifierEval.new(force_rules: true).run
    e.misses.each do |m|
      assert m.expected.present?
      assert m.got.present?
      assert m.note.present?
      assert_includes [true, false], m.costly
    end
  end

  test "confusion matrix rows sum to the number of cases for that label" do
    e = ClassifierEval.new(force_rules: true).run
    by_label = ClassifierEval.cases.group_by(&:expected).transform_values(&:size)
    e.confusion.each { |expected, got| assert_equal by_label[expected], got.values.sum }
  end

  test "costly misses are a subset of misses" do
    e = ClassifierEval.new(force_rules: true).run
    assert_operator e.costly_misses.size, :<=, e.misses.size
    e.costly_misses.each { |m| assert m.costly }
  end
end
