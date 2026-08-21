class QueueController < ApplicationController
  def index
    @lenders = Lender.order(:name)
    @lender = params[:lender_id] ? Lender.find(params[:lender_id]) : @lenders.first
    scope = @lender ? @lender.servicing_cases : ServicingCase.none
    @cases = scope.includes(:loan, :events, :replies).order(:due_on).to_a
    @cases = @cases.select(&:open?) unless params[:all] == "1"
    @cases = @cases.sort_by { |c| [-c.days_waiting, c.due_on || Date.current] }
    @needs_review = @cases.select { |c| c.replies.any?(&:needs_review?) }
  end

  def show
    @case = ServicingCase.includes(:events, :replies, :loan, :lender).find(params[:id])
    @events = @case.events.chronological
    @replies = @case.replies.order(received_at: :desc)
  end

  # Promote a model reading into a fact. This is the only path from a classification to
  # an event, and it requires a person -- see ServicingCase and Reply for why.
  def promote
    @case = ServicingCase.find(params[:id])
    reply = @case.replies.find(params[:reply_id])

    if reply.intent == "promise_to_pay" && reply.promised_on.present?
      Event.record!(servicing_case: @case, kind: "promise_recorded", actor: "servicer:demo",
                    payload: { "promised_on" => reply.promised_on.iso8601,
                               "amount_cents" => reply.promised_amount_cents || @case.amount_cents,
                               "from_reply" => reply.id, "confidence_pct" => reply.confidence_pct },
                    idempotency_key: "promote-reply-#{reply.id}")
      notice = "Promise recorded. Promoting the same reply again is a no-op."
    else
      Event.record!(servicing_case: @case, kind: "note_added", actor: "servicer:demo",
                    payload: { "intent" => reply.intent, "from_reply" => reply.id },
                    idempotency_key: "promote-reply-#{reply.id}")
      notice = "Filed as a note. Only a dated promise becomes a scheduled promise event."
    end

    redirect_to servicing_case_path(@case), notice: notice
  end

  def classify
    @case = ServicingCase.find(params[:id])
    reply = @case.replies.find(params[:reply_id])
    ReplyClassifier.classify!(reply)
    redirect_to servicing_case_path(@case), notice: "Re-read with #{reply.classifier}."
  end
end
