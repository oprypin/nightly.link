require "markd"

print Markd.to_html(ARGF.gets_to_end)
