class EvaluationController < ApplicationController
  PATH = Rails.root.join("db/eval/last_run.json")

  def show
    @run = File.exist?(PATH) ? JSON.parse(File.read(PATH)) : {}
    @cases = ClassifierEval.cases
    @configured = ReplyClassifier.configured?
  end

  # One reply, live, so a reader can watch the structured output come back rather than
  # taking the recorded numbers on trust.
  def try
    @body = params[:body].to_s
    @result = ReplyClassifier.new(@body).call if @body.present?
    @run = File.exist?(PATH) ? JSON.parse(File.read(PATH)) : {}
    @cases = ClassifierEval.cases
    @configured = ReplyClassifier.configured?
    render :show
  end
end
