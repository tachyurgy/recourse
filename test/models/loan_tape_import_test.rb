require "test_helper"

class LoanTapeImportTest < ActiveSupport::TestCase
  setup do
    @lender = Lender.create!(name: "Rideau Private Capital", slug: "rideau")
  end

  TAPE = <<~CSV
    loan_id,borrower_name,borrower_email,principal,rate,maturity_date,next_payment_date
    L-1001,Dana Whitfield,dana@example.com,"245,000.00",8.75,2027-04-01,2026-09-01
    L-1002,Marcus Bell,marcus@example.com,"88,500.00",11.25,2026-11-15,2026-09-15
    L-1003,Priya Raman,priya@example.com,"512,000.00",7.50,2028-01-01,2026-09-05
  CSV

  def import(body, filename: "tape.csv")
    LoanTapeImport.new(lender: @lender, filename: filename, io: body).call
  end

  test "first import creates every loan and reports the counts" do
    r = import(TAPE)

    refute r.replayed
    assert_equal 3, r.import.created_count
    assert_equal 0, r.import.updated_count
    assert_equal 0, r.import.unchanged_count
    assert_equal 3, Loan.where(lender: @lender).count
    assert_equal 24_500_000, Loan.find_by(external_id: "L-1001").principal_cents
    assert_equal 875, Loan.find_by(external_id: "L-1001").rate_bps
  end

  test "re-importing the identical file is a replay, not a second import" do
    first = import(TAPE)
    second = import(TAPE)

    assert second.replayed
    assert_equal first.import.id, second.import.id
    assert_equal 1, Import.where(lender: @lender).count
    assert_equal 3, Loan.where(lender: @lender).count
  end

  test "a changed row updates while untouched rows are left alone" do
    import(TAPE)
    untouched_before = Loan.find_by(external_id: "L-1001").updated_at

    changed = TAPE.sub("88,500.00", "90,000.00")
    r = import(changed, filename: "tape-v2.csv")

    refute r.replayed
    assert_equal 0, r.import.created_count
    assert_equal 1, r.import.updated_count
    assert_equal 2, r.import.unchanged_count, "rows with an identical digest must not be rewritten"
    assert_equal 9_000_000, Loan.find_by(external_id: "L-1002").principal_cents
    assert_equal untouched_before.to_i, Loan.find_by(external_id: "L-1001").updated_at.to_i,
                 "an unchanged row must not have its updated_at bumped"
  end

  test "the same loan_id under a different lender is a different loan" do
    other = Lender.create!(name: "Bytown Mortgage", slug: "bytown")
    import(TAPE)
    LoanTapeImport.new(lender: other, filename: "tape.csv", io: TAPE).call

    assert_equal 3, Loan.where(lender: @lender).count
    assert_equal 3, Loan.where(lender: other).count
    assert_equal 2, Loan.where(external_id: "L-1001").count, "tenancy is part of the key"
  end

  test "the same bytes under a different lender is not a replay" do
    other = Lender.create!(name: "Bytown Mortgage", slug: "bytown")
    import(TAPE)
    r = LoanTapeImport.new(lender: other, filename: "tape.csv", io: TAPE).call

    refute r.replayed, "idempotency is scoped to the lender, not global"
    assert_equal 3, r.import.created_count
  end

  test "a tape missing a required column is rejected before anything is written" do
    bad = "loan_id,borrower_name\nL-9,Someone\n"
    assert_raises(LoanTapeImport::MissingColumns) { import(bad) }
    assert_equal 0, Loan.where(lender: @lender).count
    assert_equal 0, Import.where(lender: @lender).count
  end

  test "importing the same tape twenty times leaves one import and three loans" do
    20.times { import(TAPE) }
    assert_equal 1, Import.where(lender: @lender).count
    assert_equal 3, Loan.where(lender: @lender).count
  end

  test "blank loan_id rows are skipped rather than creating a ghost loan" do
    tape = TAPE + ",Nobody,,0,0,,\n"
    r = import(tape)
    assert_equal 3, r.import.created_count
    assert_equal 3, Loan.where(lender: @lender).count
  end
end
