CRYSTAL ?= crystal
release ?=

md_files = $(wildcard *.md)
html_files := $(md_files:.md=.html)
vendored_files := style.css
all_sources := src/nightly_link.cr $(wildcard src/*.cr) $(html_files) $(wildcard templates/*.html) logo.svg $(vendored_files)

nightly_link: $(all_sources)
	$(CRYSTAL) build --error-trace $(if $(release),--release )$<

render_md: src/render_md.cr
	$(CRYSTAL) build --error-trace $<

%.html: %.md render_md
	./render_md $< > $@

style.css: assets/style.css Makefile
	(cat assets/style.css && \
	 echo '/* https://github.com/sindresorhus/github-markdown-css */' && \
	 curl https://cdnjs.cloudflare.com/ajax/libs/github-markdown-css/5.2.0/github-markdown.css | sed 's/\.markdown-body/article/' \
	) >style.css

lib: shard.lock
	shards install

shard.lock: shard.yml
	shards update

.PHONY: test
test: $(all_sources)
	crystal spec --order=random

.PHONY: clean
clean:
	rm -f $(html_files) $(vendored_files) render_md nightly_link

.PHONY: run
run: nightly_link
	./creds.sh ./nightly_link
