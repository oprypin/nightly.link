CRYSTAL ?= crystal
release ?=

md_files = $(wildcard *.md)
html_files := $(md_files:.md=.html)

nightly_link: nightly_link.cr $(wildcard *.cr) $(html_files) $(wildcard templates/*.html)
	$(CRYSTAL) build $(if $(release),--release )$<

render_md: render_md.cr
	$(CRYSTAL) build $<

%.html: %.md render_md
	./render_md $< > $@

.PHONY: clean
clean:
	rm -f $(html_files) render_md nightly_link

.PHONY: run
run: nightly_link
	./creds.sh ./nightly_link
