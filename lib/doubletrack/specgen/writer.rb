# frozen_string_literal: true

require "json"

module Doubletrack
  module Specgen
    # Renders one reproduction (docs/formats/repros.md) as an RSpec or Minitest file.
    # Pure: the same repro and context always give the same text, on every Ruby version
    # (Ruby literals are formatted here, not with Hash#inspect, which changed in 3.4).
    class Writer
      LONG_LITERAL = 300
      COMMENT_VALUE = 160
      GEM_LINE = 'gem "doubletrack", require: false, group: :test'

      # @param framework [String] "rspec" or "minitest"
      # @param run_id [String]
      # @param from [String] current Rails version
      # @param to [String] next Rails version
      # @param gemfile [String] basename, e.g. "Gemfile"
      # @param next_gemfile [String] basename, e.g. "Gemfile.next"
      # @param snapshot [String, nil] default path relative to the spec's directory (a repro's own "snapshot" wins)
      # @param doubletrack_version [String]
      def initialize(framework:, run_id:, from:, to:, gemfile:, next_gemfile:, doubletrack_version:, snapshot: nil)
        raise ArgumentError, "unknown framework #{framework.inspect} (expected #{FRAMEWORKS.join(" or ")})" unless FRAMEWORKS.include?(framework)

        @framework = framework
        @run_id = run_id
        @from = from
        @to = to
        @gemfile = gemfile
        @next_gemfile = next_gemfile
        @snapshot = snapshot
        @version = doubletrack_version
      end

      # @param repro [Hash]
      # @return [String] Ruby source
      def render(repro)
        [header(repro), require_block, (@framework == "rspec") ? rspec(repro) : minitest(repro)].join("\n")
      end

      # Minitest class name for a finding id ("f-bb30…" → "DoubletrackReproFBb30…Test").
      def self.class_name(finding_id)
        "DoubletrackRepro#{finding_id.split(/[^A-Za-z0-9]/).reject(&:empty?).map { |p| p[0].upcase + p[1..] }.join}Test"
      end

      # A Ruby expression that evaluates to `value` (JSON-compatible data). Long values
      # become a JSON heredoc, which spans several lines; assign it before use.
      def self.literal(value)
        short = ruby(value)
        return short if short.size <= LONG_LITERAL

        body = JSON.pretty_generate(value).lines.map { |l| "  #{l}" }.join
        "JSON.parse(<<~'EXPECTED')\n#{body.chomp}\nEXPECTED"
      end

      # Text for a `#` comment line. Titles and paths come from the app's responses (JSON
      # keys), so a newline in them must not end the comment and start live code.
      def self.comment(text)
        text.to_s.gsub(/[[:cntrl:]\u0085\u2028\u2029]/) { |c| c.dump[1..-2] }
      end

      def self.ruby(value)
        case value
        when Hash then value.empty? ? "{}" : "{#{value.map { |k, v| "#{ruby(k.to_s)} => #{ruby(v)}" }.join(", ")}}"
        when Array then "[#{value.map { |v| ruby(v) }.join(", ")}]"
        when String, Integer, Float, true, false, nil then value.inspect
        else raise ArgumentError, "not JSON-compatible: #{value.class}"
        end
      end

      private

      def header(repro)
        c = self.class.method(:comment)
        id = repro["finding_id"]
        file = c.call("#{(@framework == "rspec") ? "spec" : "test"}/doubletrack/#{Specgen.file_name(@framework, id)}")
        run = (@framework == "rspec") ? "rspec" : "ruby -Itest"
        before = repro["requests_before"] || repro["requests"].size
        after = repro["requests"].size
        lines = [
          "# frozen_string_literal: true",
          "",
          "# Doubletrack reproduction: #{c.call(id)} [#{c.call(repro["severity"])}]",
          "#   #{c.call(repro["title"])}",
          "#"
        ]
        run_id, from, to = [@run_id, @from, @to].map { |v| c.call(v) }
        if repro["status"] == "reproduced"
          lines << "# Verified in run #{run_id}: passes on Rails #{from}, fails on Rails #{to}."
        else
          lines << "# NOT verified: in run #{run_id}, replaying these requests on their own did not reproduce"
          lines << "# the difference (expected to pass on Rails #{from} and fail on Rails #{to})."
        end
        observed = repro["observed"] || {}
        [["Control A", "control_a", @from], ["Control A′", "control_a_prime", @from], ["Candidate B", "candidate_b", @to]].each do |label, role, version|
          next unless observed[role]

          lines << "#   #{"#{label} (#{c.call(version)}):".ljust(24)} #{comment_value(observed[role])}"
        end
        lines << if after < before
          "# Requests: #{before} → #{after} request#{"s" unless after == 1} (minimized; the last is the finding's request)."
        else
          "# Requests: #{after} (none could be dropped; the last is the finding's request)."
        end
        lines.push(
          "#",
          "# Run it from the app root:",
          "#   bundle exec #{run} #{file}",
          "#   BUNDLE_GEMFILE=#{c.call(@next_gemfile)} bundle exec #{run} #{file}",
          "#",
          "# The requests replay in a separate process of your app (`doubletrack` environment),",
          "# on a copy of the run's database snapshot, with the clock frozen and rand seeded as",
          "# in the run. Values are compared after Doubletrack's normalization.",
          "# Generated by Doubletrack #{c.call(@version)}. See docs/design/specgen.md in the Doubletrack repository.",
          ""
        )
        lines.join("\n")
      end

      def comment_value(encoded)
        text = self.class.comment(encoded["absent"] ? "<absent>" : self.class.ruby(encoded["value"]))
        (text.size > COMMENT_VALUE) ? "#{text[0, COMMENT_VALUE]}…" : text
      end

      def require_block
        <<~RUBY
          require "json"
          begin
            require "doubletrack/repro"
          rescue LoadError
            raise LoadError, 'Doubletrack reproduction specs need the gem in your bundle: add `#{GEM_LINE}` to your Gemfile'
          end
        RUBY
      end

      def replay_call(repro, indent)
        pad = " " * indent
        args = [
          "snapshot: File.expand_path(#{(repro["snapshot"] || @snapshot).inspect}, __dir__)",
          "started_at: #{repro["started_at"].inspect}",
          "seed: #{Integer(repro["seed"])}",
          "perform_jobs: #{repro["perform_jobs"] ? "true" : "false"}",
          "requests: [\n#{repro["requests"].map { |r| "#{pad}    #{self.class.ruby(r)}" }.join(",\n")}\n#{pad}  ]",
          "http_stubs: #{self.class.ruby(repro["http_stubs"] || [])}"
        ]
        normalize = repro["normalize"] || {}
        %w[ignored_headers ignored_columns].each do |key|
          values = Array(normalize[key])
          args << "#{key}: #{self.class.ruby(values)}" unless values.empty?
        end
        "#{pad}replay = Doubletrack::Repro.replay(\n#{args.map { |a| "#{pad}  #{a}" }.join(",\n")}\n#{pad})"
      end

      def actual(repro)
        "replay.last.at(#{repro["segments"].map { |s| s.is_a?(Integer) ? s.to_s : s.to_s.inspect }.join(", ")})"
      end

      # [setup lines, assertion] for the expected value. The comparison is as strict as
      # verification (Repro.same?: 1 is not 1.0), so a verified spec fails on the next Rails:
      # `eql` in RSpec, Repro.same? in Minitest (assert_equal would use ==).
      def assertion(repro, indent)
        pad = " " * indent
        value = repro["expected"]
        if repro["expected_absent"]
          return ["", (@framework == "rspec") ? "expect(#{actual(repro)}).to be(Doubletrack::Repro::ABSENT)" : "assert_same(Doubletrack::Repro::ABSENT, #{actual(repro)})"]
        end
        if value.nil?
          return ["", (@framework == "rspec") ? "expect(#{actual(repro)}).to be_nil" : "assert_nil(#{actual(repro)})"]
        end

        literal = self.class.literal(value)
        return ["", "expect(#{actual(repro)}).to eql(#{literal})"] if @framework == "rspec" && !literal.include?("\n")

        first, *rest = literal.lines
        setup = "#{pad}expected = #{first}#{rest.map { |l| "#{pad}#{l}" }.join}\n"
        return [setup, "expect(#{actual(repro)}).to eql(expected)"] if @framework == "rspec"

        [setup + "#{pad}actual = #{actual(repro)}\n",
          "assert(Doubletrack::Repro.same?(expected, actual), message { diff(expected, actual) })"]
      end

      def rspec(repro)
        setup, check = assertion(repro, 4)
        [
          "RSpec.describe #{"Doubletrack #{repro["finding_id"]}: #{repro["title"]}".inspect} do",
          "  it #{"keeps the Rails #{@from} behavior".inspect} do",
          replay_call(repro, 4),
          "",
          "#{setup}    #{check}",
          "  end",
          "end",
          ""
        ].join("\n")
      end

      def minitest(repro)
        setup, check = assertion(repro, 4)
        [
          'require "minitest/autorun"',
          "",
          "class #{self.class.class_name(repro["finding_id"])} < Minitest::Test",
          "  def test_keeps_the_rails_#{@from.gsub(/\W/, "_")}_behavior",
          replay_call(repro, 4),
          "",
          "#{setup}    #{check}",
          "  end",
          "end",
          ""
        ].join("\n")
      end
    end
  end
end
