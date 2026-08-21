require "test_helper"

class EventAndCaseTest < ActiveSupport::TestCase
  setup do
    @lender = Lender.create!(name: "Rideau Private Capital", slug: "rideau")
    @loan = Loan.create!(lender: @lender, external_id: "L-1001", borrower_name: "Dana Whitfield",
                         principal_cents: 24_500_000, rate_bps: 875, row_digest: "x", as_of: Time.current)
    @case = ServicingCase.create!(lender: @lender, loan: @loan, kind: "nsf_collection",
                                  amount_cents: 145_000, due_on: Date.current)
  end

  def record(kind, at: Time.current, **kw)
    Event.record!(servicing_case: @case, kind: kind, occurred_at: at, **kw)
  end

  test "an event cannot be updated" do
    e = record("opened")
    assert_raises(Event::Immutable) { e.update!(kind: "closed") }
    assert_equal "opened", e.reload.kind
  end

  test "an event cannot be destroyed" do
    e = record("opened")
    assert_raises(Event::Immutable) { e.destroy }
    assert Event.exists?(e.id)
  end

  test "case state is the last event that maps to a state" do
    assert_equal "open", @case.state

    record("opened", at: 4.days.ago)
    assert_equal "open", @case.reload.state

    record("outreach_sent", at: 3.days.ago)
    assert_equal "awaiting_borrower", @case.reload.state

    record("promise_recorded", at: 2.days.ago)
    assert_equal "promised", @case.reload.state

    record("payment_cleared", at: 1.day.ago)
    assert_equal "resolved", @case.reload.state
  end

  test "state is ordered by occurred_at, not by insertion order" do
    record("payment_cleared", at: 1.day.ago)
    record("outreach_sent", at: 5.days.ago)

    assert_equal "resolved", @case.reload.state,
                 "a backfilled older event must not overwrite a newer fact"
  end

  test "an event kind that maps to no state is recorded but does not change state" do
    record("opened", at: 2.days.ago)
    record("note_added", at: 1.day.ago)
    assert_equal "open", @case.reload.state
    assert_equal 2, @case.events.count
  end

  test "recording the same idempotency key twice yields one event" do
    a = record("outreach_sent", idempotency_key: "nsf-L-1001-2026-08-21")
    b = record("outreach_sent", idempotency_key: "nsf-L-1001-2026-08-21")

    assert_equal a.id, b.id
    assert_equal 1, @case.events.count
  end

  test "the same idempotency key under a different lender is a different event" do
    other = Lender.create!(name: "Bytown Mortgage", slug: "bytown")
    loan = Loan.create!(lender: other, external_id: "L-1001", borrower_name: "Other",
                        principal_cents: 1, rate_bps: 1, row_digest: "y", as_of: Time.current)
    kase = ServicingCase.create!(lender: other, loan: loan, kind: "nsf_collection")

    record("outreach_sent", idempotency_key: "shared-key")
    Event.record!(servicing_case: kase, kind: "outreach_sent",
                  occurred_at: Time.current, idempotency_key: "shared-key")

    assert_equal 2, Event.where(idempotency_key: "shared-key").count
  end

  test "a job replayed fifty times sends one outreach" do
    50.times { record("outreach_sent", idempotency_key: "nsf-L-1001-2026-08-21") }
    assert_equal 1, @case.events.where(kind: "outreach_sent").count
  end

  test "days_waiting counts from the last contact in either direction" do
    record("outreach_sent", at: 9.days.ago)
    assert_equal 9, @case.reload.days_waiting

    record("borrower_replied", at: 2.days.ago)
    assert_equal 2, @case.reload.days_waiting
  end

  test "one open case per loan per kind" do
    assert_raises(ActiveRecord::RecordInvalid) do
      ServicingCase.create!(lender: @lender, loan: @loan, kind: "nsf_collection")
    end
    assert ServicingCase.create!(lender: @lender, loan: @loan, kind: "renewal").persisted?
  end
end
