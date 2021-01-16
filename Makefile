CRYSTAL ?= crystal
release ?=

md_files = $(wildcard *.md)
html_files := $(md_files:.md=.html)
vendored_files := github-markdown.min.css

nightly_link: nightly_link.cr $(wildcard *.cr) $(html_files) $(wildcard templates/*.html) $(vendored_files)
	$(CRYSTAL) build --error-trace $(if $(release),--release )$<

render_md: render_md.cr
	$(CRYSTAL) build --error-trace $<

%.html: %.md render_md
	./render_md $< > $@

github-markdown.min.css:
	curl -O https://cdnjs.cloudflare.com/ajax/libs/github-markdown-css/4.0.0/github-markdown.min.css

.PHONY: clean
clean:
	rm -f $(html_files) $(vendored_files) render_md nightly_link

.PHONY: run
run: nightly_link
	./creds.sh ./nightly_link
