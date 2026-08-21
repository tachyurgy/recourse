require "csv"
require "digest"
require "bigdecimal"

# Imports a lender's loan tape.
#
# Servicing shops re-send the same tape constantly: a nightly cron fires twice, an analyst
# re-uploads "the good one", a job retries after a timeout. So the import is idempotent at
# two levels:
#
#   1. FILE level  -- the same bytes for the same lender is recorded once (unique index on
#                     (lender_id, content_digest)) and returns the original Import.
#   2. ROW level   -- each row upserts by (lender_id, external_id). A row whose digest is
#                     unchanged is counted as unchanged and NOT rewritten, so updated_at
#                     stays honest and no spurious "loan changed" event is emitted.
#
# The counts it returns are the reconciliation an operator reads before trusting the run.
class LoanTapeImport
  Result = Struct.new(:import, :replayed, keyword_init: true)

  REQUIRED = %w[loan_id borrower_name principal rate maturity_date next_payment_date].freeze

  class MissingColumns < StandardError; end

  def initialize(lender:, filename:, io:, as_of: Time.current)
    @lender = lender
    @filename = filename
    @raw = io.respond_to?(:read) ? io.read : io.to_s
    @as_of = as_of
  end

  def call
    digest = Digest::SHA256.hexdigest(@raw)

    if (existing = Import.find_by(lender: @lender, content_digest: digest))
      return Result.new(import: existing, replayed: true)
    end

    table = CSV.parse(@raw, headers: true)
    headers = (table.headers || []).compact.map { |h| h.to_s.strip.downcase }
    missing = REQUIRED - headers
    raise MissingColumns, "loan tape is missing: #{missing.join(', ')}" if missing.any?

    created = updated = unchanged = 0
    import = nil

    begin
      ActiveRecord::Base.transaction do
        table.each do |row|
          h = row.to_h.transform_keys { |k| k.to_s.strip.downcase }
          next if h["loan_id"].to_s.strip.empty?

          attrs = {
            borrower_name:   h["borrower_name"].to_s.strip,
            borrower_email:  h["borrower_email"].to_s.strip.presence,
            principal_cents: to_cents(h["principal"]),
            rate_bps:        (h["rate"].to_f * 100).round,
            maturity_on:     parse_date(h["maturity_date"]),
            next_payment_on: parse_date(h["next_payment_date"])
          }
          row_digest = Digest::SHA256.hexdigest(attrs.values.map(&:to_s).join(" "))
          external_id = h["loan_id"].to_s.strip

          loan = Loan.find_by(lender: @lender, external_id: external_id)
          if loan.nil?
            Loan.create!(attrs.merge(lender: @lender, external_id: external_id,
                                     row_digest: row_digest, as_of: @as_of))
            created += 1
          elsif loan.row_digest == row_digest
            unchanged += 1
          else
            loan.update!(attrs.merge(row_digest: row_digest, as_of: @as_of))
            updated += 1
          end
        end

        # The unique index is the real guard: two workers racing the same file both reach
        # here, one wins, the loser raises and is handed the winner's row below.
        import = Import.create!(lender: @lender, filename: @filename, content_digest: digest,
                                row_count: table.size, created_count: created,
                                updated_count: updated, unchanged_count: unchanged, as_of: @as_of)
      end
    rescue ActiveRecord::RecordNotUnique
      return Result.new(import: Import.find_by!(lender: @lender, content_digest: digest), replayed: true)
    end

    Result.new(import: import, replayed: false)
  end

  private

  def to_cents(value)
    s = value.to_s.gsub(/[^\d.\-]/, "")
    return 0 if s.empty?
    (BigDecimal(s) * 100).round
  rescue ArgumentError
    0
  end

  def parse_date(value)
    s = value.to_s.strip
    return nil if s.empty?
    Date.parse(s)
  rescue Date::Error
    nil
  end
end
