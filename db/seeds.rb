require "csv"

puts "seeding..."
Reply.delete_all; Event.delete_all; ServicingCase.delete_all
Loan.delete_all; Import.delete_all; Lender.delete_all

lenders = [
  Lender.create!(name: "Rideau Private Capital", slug: "rideau"),
  Lender.create!(name: "Bytown Mortgage Fund",   slug: "bytown")
]

BORROWERS = [
  ["Dana Whitfield", "dana"], ["Marcus Bell", "marcus"], ["Priya Raman", "priya"],
  ["Tomas Iglesias", "tomas"], ["Nell Okonkwo", "nell"], ["Rae Lindqvist", "rae"],
  ["Ibrahim Haddad", "ibrahim"], ["Coleen Byrne", "coleen"], ["Yusuf Demir", "yusuf"],
  ["Margit Halvorsen", "margit"], ["Sam Ferreira", "sam"], ["Winnie Chau", "winnie"]
].freeze

lenders.each_with_index do |lender, li|
  rows = BORROWERS.each_with_index.map do |(name, handle), i|
    n = li * 100 + i + 1
    {
      "loan_id" => "L-#{1000 + n}",
      "borrower_name" => name,
      "borrower_email" => "#{handle}@example.com",
      "principal" => format("%.2f", 85_000 + (i * 37_500) + (li * 12_000)),
      "rate" => format("%.2f", 7.25 + (i % 6) * 0.75),
      "maturity_date" => (Date.current + (180 + i * 45)).iso8601,
      "next_payment_date" => (Date.current + (i % 20) - 8).iso8601
    }
  end

  csv = CSV.generate do |c|
    c << rows.first.keys
    rows.each { |r| c << r.values }
  end

  result = LoanTapeImport.new(lender: lender, filename: "tape-#{Date.current.iso8601}.csv", io: csv).call
  puts "  #{lender.name}: imported #{result.import.created_count} loans"

  # Replaying the same tape proves the point on a live database, not just in a test.
  replay = LoanTapeImport.new(lender: lender, filename: "tape-#{Date.current.iso8601}.csv", io: csv).call
  puts "  #{lender.name}: replay -> #{replay.replayed ? 'no-op (same import row)' : 'ERROR: duplicated'}"
end

# --- cases, events, replies -------------------------------------------------

SCRIPTS = [
  # [kind, days_ago_opened, event script, reply body or nil]
  ["nsf_collection", 9,  %w[opened outreach_sent],                          "Hi - sorry about that, I can pay the 1,450 on Friday. Will send it from the same account."],
  ["nsf_collection", 14, %w[opened outreach_sent],                          "I paid this last Tuesday, check your records. The money left my account on the 12th."],
  ["nsf_collection", 6,  %w[opened outreach_sent],                          "I was laid off three weeks ago and I honestly don't have it right now. Is there anything you can do?"],
  ["nsf_collection", 21, %w[opened outreach_sent promise_recorded promise_broken], nil],
  ["nsf_collection", 3,  %w[opened outreach_sent],                          "Do not contact me again at this address. Any further communication should go through my attorney."],
  ["nsf_collection", 11, %w[opened outreach_sent],                          "What is this about?\n\n> On Aug 4 you wrote: I will pay the 1,450 on Friday."],
  ["renewal",        30, %w[opened outreach_sent],                          "If I pay the arrears by the 30th does the default get removed from my file?"],
  ["renewal",        45, %w[opened outreach_sent promise_recorded renewal_signed], nil],
  ["renewal",        18, %w[opened outreach_sent],                          "I sold that property in 2023. This is not my loan anymore, please take me off it."],
  ["nsf_collection", 2,  %w[opened],                                        nil],
  ["nsf_collection", 27, %w[opened outreach_sent escalated],                "Oh sure, I'll get right on paying a fee for a payment that never bounced."],
  ["renewal",        8,  %w[opened outreach_sent promise_recorded],         "Putting 1,450 in on #{(Date.current + 12).iso8601}. Confirming so it is on the record."]
].freeze

lenders.each do |lender|
  loans = lender.loans.order(:external_id).to_a
  SCRIPTS.each_with_index do |(kind, days_ago, script, reply_body), i|
    loan = loans[i % loans.size]
    next if ServicingCase.exists?(lender: lender, loan: loan, kind: kind)

    kase = ServicingCase.create!(
      lender: lender, loan: loan, kind: kind,
      amount_cents: kind == "renewal" ? loan.principal_cents : (95_000 + i * 21_500),
      due_on: Date.current + (kind == "renewal" ? 30 : -days_ago + 5)
    )

    script.each_with_index do |ev, n|
      at = days_ago.days.ago + (n * 2).days
      payload = case ev
                when "promise_recorded" then { "amount_cents" => kase.amount_cents, "promised_on" => (Date.current + 5).iso8601 }
                when "outreach_sent"    then { "template" => kind == "renewal" ? "renewal_60d" : "nsf_first_notice" }
                else {}
                end
      Event.record!(servicing_case: kase, kind: ev, actor: ev == "opened" ? "system" : "servicer:kbrandt",
                    payload: payload, occurred_at: at,
                    idempotency_key: "#{kase.id}-#{ev}-#{n}")
    end

    next unless reply_body

    reply = Reply.create!(lender: lender, servicing_case: kase, body: reply_body,
                          received_at: (days_ago - 1).days.ago)
    Event.record!(servicing_case: kase, kind: "borrower_replied", actor: "borrower",
                  payload: { "reply_id" => reply.id }, occurred_at: reply.received_at,
                  idempotency_key: "#{kase.id}-reply-#{reply.id}")
    ReplyClassifier.classify!(reply, force_rules: !ReplyClassifier.configured?)
  end
end

puts "  lenders=#{Lender.count} loans=#{Loan.count} cases=#{ServicingCase.count} events=#{Event.count} replies=#{Reply.count}"
puts "done."
