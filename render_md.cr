require "markd"

print Markd.to_html(ARGF.gets_to_end).gsub(/<include (\S+)>/, %(<% ECR.embed("templates/\\1.html", io) %>))
