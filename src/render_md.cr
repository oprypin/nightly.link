require "markd"

print Markd.to_html(ARGF.gets_to_end)
  .gsub(/^<(h[1-6])>([^<>]+?)<\/\1>$/m) { %(<#{$1} id="#{$2.gsub(/\W+/, "-").downcase}">#{$2}</#{$1}>) }
  .gsub(/<include (\S+)>/, %(<% ECR.embed("\#{__DIR__}/templates/\\1.html", ctx.response) %>))
