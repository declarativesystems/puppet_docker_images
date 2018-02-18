image:
	bundle install
	bundle exec ./build_image.rb --pe-version $$(ls puppet-enterprise*.tar.gz | tail -n1 | awk 'match($$0, /([[:digit:]]{4}\.[[:digit:]]\.[[:digit:]])/, a) {print a[1]}') --tag-version 0

