class ImportsController < ApplicationController
  def index
    @lenders = Lender.order(:name)
    @lender = params[:lender_id] ? Lender.find(params[:lender_id]) : @lenders.first
    @imports = @lender ? @lender.imports.order(created_at: :desc) : []
  end

  def create
    lender = Lender.find(params[:lender_id])
    body = params[:tape].presence || sample_tape(lender)
    result = LoanTapeImport.new(lender: lender, filename: params[:filename].presence || "pasted.csv", io: body).call

    notice = if result.replayed
      "Replay: these exact bytes were already imported as ##{result.import.id}. Nothing was written."
    else
      i = result.import
      "Imported ##{i.id}: #{i.created_count} created, #{i.updated_count} updated, #{i.unchanged_count} unchanged."
    end
    redirect_to imports_path(lender_id: lender.id), notice: notice
  rescue LoanTapeImport::MissingColumns => e
    redirect_to imports_path(lender_id: params[:lender_id]), alert: e.message
  end

  private

  def sample_tape(lender)
    loan = lender.loans.order(:external_id).first
    <<~CSV
      loan_id,borrower_name,borrower_email,principal,rate,maturity_date,next_payment_date
      #{loan&.external_id || 'L-9001'},#{loan&.borrower_name || 'New Borrower'},new@example.com,"250,000.00",8.50,#{Date.current + 365},#{Date.current + 30}
    CSV
  end
end
