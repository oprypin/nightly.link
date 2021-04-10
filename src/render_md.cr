require "markd"

print Markd.to_html(ARGF.gets_to_end).gsub(/<include (\S+)>/, %(<% ECR.embed("\#{__DIR__}/templates/\\1.html", ctx.response) %>))
