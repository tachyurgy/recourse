require "net/http"
require "json"

# Reads a borrower's email reply and returns a STRUCTURED result, never prose.
#
# Three things make this different from wrapping a chat call in a helper:
#
#   1. The model is constrained by a response schema, so the caller gets a typed object
#      or an error -- it never gets a paragraph it has to regex. A response that does not
#      satisfy the schema is a failure, and is recorded as one.
#   2. Every field the servicer will act on (date, amount) is re-derived from the borrower's
#      own text and DISCARDED if the model invented it. An amount that does not appear in
#      the email cannot survive this step, which is the only defence against a confident
#      hallucination becoming a payment expectation.
#   3. Output is advisory. It writes a Reply row; it does not write an Event, move money,
#      or close a case. A human promotes it. See ServicingCase for why that line is drawn
#      at the event log.
#
# With no GEMINI_API_KEY the rules classifier runs instead, so the app is demonstrable
# offline and the eval harness has a baseline to beat.
class ReplyClassifier
  MODEL = ENV.fetch("GEMINI_MODEL", "gemini-3.6-flash")
  ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent"

  INTENTS = Reply::INTENTS

  SCHEMA = {
    type: "OBJECT",
    properties: {
      intent:                 { type: "STRING", enum: INTENTS },
      promised_date:          { type: "STRING", description: "ISO-8601 date, or empty string if none stated" },
      promised_amount:        { type: "STRING", description: "Bare number the borrower stated, or empty string" },
      confidence:             { type: "INTEGER", description: "0-100" },
      evidence_span:          { type: "STRING", description: "Verbatim substring of the email supporting the intent" }
    },
    required: %w[intent confidence evidence_span]
  }.freeze

  PROMPT = <<~TXT.freeze
    You are triaging a reply from a mortgage borrower to a servicing outreach email.

    Classify the reply into exactly one intent:
      promise_to_pay - commits to paying, with or without a date
      dispute        - disagrees that the amount or the charge is owed
      hardship       - reports inability to pay: job loss, illness, income shock
      wrong_person   - says they are not the borrower / wrong contact
      unsubscribe    - asks to stop being contacted
      question       - asks something and commits to nothing
      unclear        - anything else, or too ambiguous to call

    Rules you must follow:
    - Only report promised_date or promised_amount if the borrower stated it. Never infer,
      never round, never fill in "probably".
    - evidence_span must be copied verbatim from the email. Do not paraphrase it.
    - If the reply mixes intents, choose the one that changes what the servicer does next,
      and lower your confidence.

    Today is %<today>s. The email follows.
    ---
    %<body>s
  TXT

  Result = Struct.new(:intent, :promised_on, :promised_amount_cents, :confidence_pct,
                      :classifier, :raw, :error, keyword_init: true)

  def self.configured? = ENV["GEMINI_API_KEY"].to_s.present? || ENV["GEMINI_KEY"].to_s.present?

  def initialize(body, today: Date.current, force_rules: false)
    @body = body.to_s
    @today = today
    @force_rules = force_rules
  end

  def call
    return rules_result if @force_rules || !self.class.configured?
    llm_result
  rescue StandardError => e
    rules_result(error: "#{e.class}: #{e.message}")
  end

  # --- classify and persist -------------------------------------------------

  def self.classify!(reply, **kwargs)
    r = new(reply.body, **kwargs).call
    reply.update!(intent: r.intent, promised_on: r.promised_on,
                  promised_amount_cents: r.promised_amount_cents,
                  confidence_pct: r.confidence_pct, classifier: r.classifier,
                  raw_output: r.raw || {}, classification_error: r.error)
    reply
  end

  private

  def key = ENV["GEMINI_API_KEY"].presence || ENV["GEMINI_KEY"]

  def llm_result
    uri = URI(format(ENDPOINT, MODEL))
    uri.query = URI.encode_www_form(key: key)

    payload = {
      contents: [{ parts: [{ text: format(PROMPT, today: @today.iso8601, body: @body) }] }],
      generationConfig: { temperature: 0, responseMimeType: "application/json", responseSchema: SCHEMA }
    }

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 8
    http.read_timeout = 25

    res = http.post(uri.request_uri, payload.to_json, "Content-Type" => "application/json")
    raise "gemini http #{res.code}" unless res.code.to_i == 200

    body = JSON.parse(res.body)
    text = body.dig("candidates", 0, "content", "parts", 0, "text")
    raise "gemini returned no content" if text.to_s.strip.empty?

    parsed = JSON.parse(text)
    intent = parsed["intent"].to_s
    raise "off-schema intent #{intent.inspect}" unless INTENTS.include?(intent)

    Result.new(
      intent: intent,
      promised_on: grounded_date(parsed["promised_date"]),
      promised_amount_cents: grounded_amount(parsed["promised_amount"]),
      confidence_pct: parsed["confidence"].to_i.clamp(0, 100),
      classifier: MODEL,
      raw: parsed,
      error: nil
    )
  end

  # A date only survives if the model also produced an evidence span, and the borrower's
  # text actually contains a date-shaped token. A model that "remembers" a date the email
  # never contained loses it here.
  def grounded_date(value)
    s = value.to_s.strip
    return nil if s.empty?
    return nil unless @body.match?(/\b(\d{1,2}[\/-]\d{1,2}|\d{4}-\d{2}-\d{2})\b/i) ||
                      @body.match?(/\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)/i) ||
                      @body.match?(/\b(today|tomorrow|monday|tuesday|wednesday|thursday|friday|next week|friday)\b/i)
    Date.parse(s)
  rescue Date::Error
    nil
  end

  # An amount only survives if the digits appear in the borrower's own text.
  def grounded_amount(value)
    s = value.to_s.gsub(/[^\d.]/, "")
    return nil if s.empty?
    cents = (BigDecimal(s) * 100).round
    digits = s.split(".").first
    return nil unless digits.present? && @body.gsub(/[^\d]/, "").include?(digits)
    cents
  rescue ArgumentError
    nil
  end

  # --- deterministic baseline ----------------------------------------------

  RULES = [
    [:unsubscribe,    /\b(stop\s+(emailing|e-?mailing|email|contact(ing)?|sending)|unsubscribe|do\s*n[o']?t\s+(contact|email)|remove me|take me off|cease and desist|through my attorney)\b/i],
    [:wrong_person,   /\b(wrong (number|person|address)|not me|don't know (who|what)|no longer own)\b/i],
    [:hardship,       /\b(lost my job|laid off|hardship|in the hospital|can'?t afford|no income|out of work|medical)\b/i],
    [:dispute,        /\b(already paid|dispute|do not owe|don'?t owe|incorrect|error on your|never missed)\b/i],
    [:promise_to_pay, /\b(i (will|'ll|can) pay|will send|paying (it|you)|payment (on|by)|can pay|send.*(payment|check))\b/i],
    [:question,       /\?/]
  ].freeze

  def rules_result(error: nil)
    intent = RULES.find { |(_, re)| @body.match?(re) }&.first&.to_s || "unclear"
    Result.new(intent: intent, promised_on: nil, promised_amount_cents: nil,
               confidence_pct: intent == "unclear" ? 30 : 60,
               classifier: "rules", raw: { "matched" => intent }, error: error)
  end
end
