# A borrower's inbound email, plus the model's structured reading of it.
#
# A classification is EVIDENCE, not an instruction. Nothing here moves money or closes a
# case on its own — it proposes, a servicer confirms, and the confirmation is the event.
# That boundary is the whole reason this is safe to point at a real loan book.
class Reply < ApplicationRecord
  INTENTS = %w[promise_to_pay dispute hardship wrong_person unsubscribe question unclear].freeze

  belongs_to :lender
  belongs_to :servicing_case

  validates :body, :received_at, presence: true
  validates :intent, inclusion: { in: INTENTS }, allow_nil: true

  scope :classified, -> { where.not(intent: nil) }

  def classified? = intent.present?
  def low_confidence? = confidence_pct.present? && confidence_pct < 70
  def promised_amount = promised_amount_cents ? promised_amount_cents / 100.0 : nil

  # Requires a human before it can become a promise event.
  def needs_review?
    return true if intent.nil? || intent == "unclear"
    return true if low_confidence?
    return true if intent == "promise_to_pay" && promised_on.nil?
    false
  end
end
