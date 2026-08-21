class Loan < ApplicationRecord
  belongs_to :lender
  has_many :servicing_cases, dependent: :destroy
  validates :external_id, :borrower_name, :row_digest, :as_of, presence: true
  validates :external_id, uniqueness: { scope: :lender_id }

  def principal = principal_cents / 100.0
  def rate_pct  = rate_bps / 100.0
end
