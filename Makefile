CRYSTAL ?= crystal
release ?=

md_files = $(wildcard *.md)
html_files := $(md_files:.md=.html)

main: main.cr $(wildcard *.cr) $(html_files) $(wildcard templates/*.html)
	$(CRYSTAL) build $(if $(release),--release )$<

render_md: render_md.cr
	$(CRYSTAL) build $<

%.html: %.md render_md
	./render_md $< > $@

.PHONY: clean
clean:
	rm -f $(html_files) render_md main

.PHONY: run
run: main
	./creds.sh ./main
