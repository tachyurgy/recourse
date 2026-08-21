# A unit of servicing work: chase an NSF, or work a renewal to a decision.
#
# The case has NO status column. Status is a fold over the append-only event log, so
# the work queue and the audit trail can never disagree with each other — a class of
# bug that is otherwise permanent, silent, and discovered by a regulator.
class ServicingCase < ApplicationRecord
  KINDS  = %w[nsf_collection renewal].freeze
  STATES = %w[open awaiting_borrower promised escalated resolved].freeze

  belongs_to :lender
  belongs_to :loan
  has_many :events, dependent: :destroy
  has_many :replies, dependent: :destroy

  validates :kind, inclusion: { in: KINDS }
  validates :loan_id, uniqueness: { scope: [:lender_id, :kind] }

  # Ordered most-specific-last: later facts win.
  TRANSITIONS = {
    "opened"            => "open",
    "outreach_sent"     => "awaiting_borrower",
    "borrower_replied"  => "awaiting_borrower",
    "promise_recorded"  => "promised",
    "promise_broken"    => "escalated",
    "escalated"         => "escalated",
    "payment_cleared"   => "resolved",
    "renewal_signed"    => "resolved",
    "closed"            => "resolved"
  }.freeze

  def state
    events.chronological.reverse_each do |e|
      s = TRANSITIONS[e.kind]
      return s if s
    end
    "open"
  end

  def promised_payment
    events.chronological.select { |e| e.kind == "promise_recorded" }.last
  end

  # Age of the oldest unanswered outreach — what a servicing supervisor actually sorts by.
  def days_waiting
    last = events.chronological.select { |e| %w[outreach_sent borrower_replied].include?(e.kind) }.last
    return 0 unless last
    ((Time.current - last.occurred_at) / 86_400).floor
  end

  def amount = amount_cents / 100.0
  def open? = !%w[resolved].include?(state)
end
