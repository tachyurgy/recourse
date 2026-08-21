require "yaml"

# Runs the labelled set through a classifier and reports accuracy, a confusion matrix,
# and the individual misses.
#
# The point of keeping this in the app rather than in a notebook is that the failure modes
# are the interesting output, not the headline number. A servicing tool can tolerate a
# borrower question being filed as unclear. It cannot tolerate a hardship being read as a
# promise to pay, because that schedules a draft against an account the borrower already
# said is empty, which is an NSF fee charged to someone who told you not to. So the report
# separates ordinary misses from the ones that cost the lender money or a complaint.
class ClassifierEval
  FIXTURE = Rails.root.join("db", "eval", "borrower_replies.yml")

  # Confusing the key with the value is a costly miss, not just a wrong label.
  COSTLY = {
    "hardship"       => %w[promise_to_pay],
    "dispute"        => %w[promise_to_pay],
    "unsubscribe"    => %w[promise_to_pay question],
    "wrong_person"   => %w[promise_to_pay hardship]
  }.freeze

  Case = Struct.new(:id, :body, :expected, :note, keyword_init: true)
  Miss = Struct.new(:id, :body, :expected, :got, :confidence, :costly, :note, keyword_init: true)

  attr_reader :results

  def self.cases
    YAML.load_file(FIXTURE).map { |h| Case.new(**h.transform_keys(&:to_sym)) }
  end

  def initialize(force_rules: false, cases: nil)
    @force_rules = force_rules
    @cases = cases || self.class.cases
  end

  def run
    @results = @cases.map do |c|
      out = ReplyClassifier.new(c.body, force_rules: @force_rules).call
      { case: c, got: out.intent, confidence: out.confidence_pct,
        classifier: out.classifier, error: out.error, hit: out.intent == c.expected }
    end
    self
  end

  def total    = @results.size
  def hits     = @results.count { |r| r[:hit] }
  def accuracy = total.zero? ? 0.0 : (hits.to_f / total * 100).round(1)
  def classifier_name = @results.first&.dig(:classifier) || "n/a"
  def errored = @results.count { |r| r[:error].present? }

  def misses
    @results.reject { |r| r[:hit] }.map do |r|
      c = r[:case]
      Miss.new(id: c.id, body: c.body, expected: c.expected, got: r[:got],
               confidence: r[:confidence], note: c.note,
               costly: COSTLY.fetch(c.expected, []).include?(r[:got]))
    end
  end

  def costly_misses = misses.select(&:costly)

  # rows: expected -> { got => count }
  def confusion
    m = Hash.new { |h, k| h[k] = Hash.new(0) }
    @results.each { |r| m[r[:case].expected][r[:got]] += 1 }
    m
  end

  def per_intent
    confusion.map do |expected, got|
      n = got.values.sum
      correct = got[expected]
      { intent: expected, n: n, correct: correct,
        pct: n.zero? ? 0.0 : (correct.to_f / n * 100).round(1) }
    end.sort_by { |h| -h[:n] }
  end
end
