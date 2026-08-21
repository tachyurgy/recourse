require "test_helper"

# These run against the deterministic rules classifier so the suite is hermetic and does
# not depend on a network or a key. The grounding guards are tested directly, because they
# are what stands between a confident model and a wrong payment expectation.
class ReplyClassifierTest < ActiveSupport::TestCase
  setup do
    @lender = Lender.create!(name: "Rideau Private Capital", slug: "rideau")
    @loan = Loan.create!(lender: @lender, external_id: "L-1001", borrower_name: "Dana Whitfield",
                         principal_cents: 24_500_000, rate_bps: 875, row_digest: "x", as_of: Time.current)
    @case = ServicingCase.create!(lender: @lender, loan: @loan, kind: "nsf_collection", amount_cents: 145_000)
  end

  def classify(body)
    ReplyClassifier.new(body, force_rules: true).call
  end

  test "the rules baseline resolves the obvious classes" do
    assert_equal "unsubscribe",    classify("Stop emailing me.").intent
    assert_equal "wrong_person",   classify("You have the wrong number, not me.").intent
    assert_equal "hardship",       classify("I was laid off three weeks ago.").intent
    assert_equal "dispute",        classify("I already paid this last Tuesday.").intent
    assert_equal "promise_to_pay", classify("I will pay the 1450 on Friday.").intent
    assert_equal "unclear",        classify("ok").intent
  end

  test "unsubscribe outranks a payment mention in the same email" do
    r = classify("I will pay it eventually but stop emailing me about it.")
    assert_equal "unsubscribe", r.intent,
                 "a contact-cessation request is the highest-cost signal to miss"
  end

  test "hardship outranks a payment intention" do
    r = classify("I want to pay you but I lost my job and have no income.")
    assert_equal "hardship", r.intent
  end

  test "an amount the borrower never wrote is discarded" do
    c = ReplyClassifier.new("I'll get something over to you soon.")
    assert_nil c.send(:grounded_amount, "1450.00"),
               "a model-invented amount must not survive grounding"
  end

  test "an amount the borrower did write survives" do
    c = ReplyClassifier.new("I can send 1450 on Friday.")
    assert_equal 145_000, c.send(:grounded_amount, "1450")
  end

  test "a date is only kept when the email contains a date-shaped token" do
    bare = ReplyClassifier.new("I'll pay it when I can.")
    assert_nil bare.send(:grounded_date, "2026-09-03")

    dated = ReplyClassifier.new("Putting it in on 2026-09-03.")
    assert_equal Date.new(2026, 9, 3), dated.send(:grounded_date, "2026-09-03")
  end

  test "a fee figure in a question does not become a promised amount" do
    r = classify("Is the 45 dollar fee on top of the payment or included?")
    assert_equal "question", r.intent
    assert_nil r.promised_amount_cents
  end

  test "classify! persists the structured result onto the reply" do
    reply = Reply.create!(lender: @lender, servicing_case: @case, received_at: Time.current,
                          body: "I will pay the 1450 on Friday.")
    ReplyClassifier.classify!(reply, force_rules: true)

    reply.reload
    assert_equal "promise_to_pay", reply.intent
    assert_equal "rules", reply.classifier
    assert reply.confidence_pct.positive?
  end

  test "classification never writes an event or changes case state" do
    reply = Reply.create!(lender: @lender, servicing_case: @case, received_at: Time.current,
                          body: "I will pay the 1450 on Friday.")
    before = @case.events.count

    ReplyClassifier.classify!(reply, force_rules: true)

    assert_equal before, @case.reload.events.count,
                 "a classification is evidence; only a human promotion writes an event"
    assert_equal "open", @case.state
  end

  test "a low-confidence or dateless promise is flagged for review" do
    reply = Reply.create!(lender: @lender, servicing_case: @case, received_at: Time.current,
                          body: "I'll get it paid soon.")
    ReplyClassifier.classify!(reply, force_rules: true)

    assert reply.reload.needs_review?, "a promise with no date cannot be scheduled unattended"
  end

  test "a transport failure degrades to the baseline and records the error" do
    with_env("GEMINI_API_KEY" => "test-key") do
      c = ReplyClassifier.new("I will pay 1450 on Friday.")
      c.define_singleton_method(:llm_result) { raise StandardError, "gemini http 503" }

      r = c.call
      assert_equal "promise_to_pay", r.intent, "a dead upstream must not lose the reply"
      assert_equal "rules", r.classifier
      assert_match(/503/, r.error.to_s)
    end
  end

  test "an off-schema intent from the model is treated as a failure, not coerced" do
    with_env("GEMINI_API_KEY" => "test-key") do
      c = ReplyClassifier.new("I will pay 1450 on Friday.")
      c.define_singleton_method(:llm_result) { raise StandardError, 'off-schema intent "will_pay"' }

      r = c.call
      assert_equal "rules", r.classifier
      assert_match(/off-schema/, r.error.to_s)
    end
  end

  private

  def with_env(vars)
    old = vars.keys.index_with { |k| ENV[k] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end
end
