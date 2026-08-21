class Lender < ApplicationRecord
  has_many :loans, dependent: :destroy
  has_many :servicing_cases, dependent: :destroy
  has_many :imports, dependent: :destroy
  has_many :events, dependent: :destroy
  validates :name, :slug, presence: true
  validates :slug, uniqueness: true
end
