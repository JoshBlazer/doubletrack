.PHONY: test lint integration spike fixtures eval run-shop

FIXTURE_APPS = fixtures/apps/shop fixtures/apps/planted/changes fixtures/apps/planted/clean

test:
	bundle exec rake spec

lint:
	bundle exec rake standard

fixtures:
	for app in $(FIXTURE_APPS); do (cd $$app && bundle install && BUNDLE_GEMFILE=Gemfile.next bundle install) || exit 1; done

integration:
	bundle exec rake spec:integration

spike:
	ruby bin/doubletrack-spike fixtures/apps/shop --path /orders

# M3: replay shop on Rails 8.0 (A, A') and 8.1 (B); exit 1 means findings, which is fine here.
run-shop:
	bundle exec exe/doubletrack run fixtures/apps/shop --seed 42 || [ $$? -eq 1 ]

# Precision/recall on the planted fixtures; writes eval/results/<date>.json; exit 1 on regression.
eval:
	bundle exec ruby eval/run.rb
