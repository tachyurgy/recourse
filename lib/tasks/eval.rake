namespace :eval do
  desc "Run the labelled set through both classifiers and record the result"
  task run: :environment do
    out = {}
    [["rules", true], ["model", false]].each do |label, force|
      next if label == "model" && !ReplyClassifier.configured?
      t0 = Time.current
      e = ClassifierEval.new(force_rules: force).run
      out[label] = {
        "classifier" => e.classifier_name, "accuracy" => e.accuracy,
        "hits" => e.hits, "total" => e.total, "errored" => e.errored,
        "seconds" => (Time.current - t0).round(1),
        "per_intent" => e.per_intent.map { |h| h.transform_keys(&:to_s) },
        "confusion" => e.confusion,
        "misses" => e.misses.map { |m| { "id" => m.id, "expected" => m.expected, "got" => m.got,
                                         "confidence" => m.confidence, "costly" => m.costly,
                                         "note" => m.note, "body" => m.body } },
        "costly" => e.costly_misses.size
      }
      puts "#{label}: #{e.accuracy}% (#{e.hits}/#{e.total}) costly=#{e.costly_misses.size} err=#{e.errored} in #{out[label]['seconds']}s"
    end
    out["ran_at"] = Time.current.iso8601
    File.write(Rails.root.join("db/eval/last_run.json"), JSON.pretty_generate(out))
    puts "wrote db/eval/last_run.json"
  end
end
