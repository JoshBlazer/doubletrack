.PHONY: test lint integration spike fixtures eval

test:
	bundle exec rake spec

lint:
	bundle exec rake standard

fixtures:
	cd fixtures/apps/shop && bundle install && BUNDLE_GEMFILE=Gemfile.next bundle install

integration:
	bundle exec rake spec:integration

spike:
	ruby bin/doubletrack-spike fixtures/apps/shop --path /orders

eval:
	@echo "make eval: not implemented yet (precision/recall harness lands with M3)" >&2; exit 2
