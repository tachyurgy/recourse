# Append-only. An event is a fact that happened; facts are not edited or deleted.
# Every state a case is in is a fold over its events, so mutating one would rewrite history.
class Event < ApplicationRecord
  class Immutable < StandardError; end

  belongs_to :lender
  belongs_to :servicing_case

  validates :kind, :actor, :occurred_at, presence: true

  before_update  { raise Immutable, "events are append-only (tried to update ##{id})" }
  before_destroy { raise Immutable, "events are append-only (tried to destroy ##{id})" }

  scope :chronological, -> { order(:occurred_at, :id) }

  # Writing the same logical event twice — a retried job, a double-clicked button, a
  # replayed webhook — must land once. The uniqueness is enforced by the database, not
  # by a read-then-write check that two workers can both pass.
  def self.record!(servicing_case:, kind:, actor: "system", payload: {}, occurred_at: Time.current, idempotency_key: nil)
    create!(lender_id: servicing_case.lender_id, servicing_case: servicing_case, kind: kind,
            actor: actor, payload: payload, occurred_at: occurred_at, idempotency_key: idempotency_key)
  rescue ActiveRecord::RecordNotUnique
    find_by!(lender_id: servicing_case.lender_id, idempotency_key: idempotency_key)
  end
end
