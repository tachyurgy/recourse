class Import < ApplicationRecord
  belongs_to :lender
  validates :filename, :content_digest, :as_of, presence: true
  def total_touched = created_count + updated_count + unchanged_count
end
