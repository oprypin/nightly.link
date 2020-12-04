require "memory_cache"
require "cron_scheduler"

macro cached_array(f)
  {{f}}

  {% typ = f.block_arg.restriction.inputs[0] %}
  @@cache_{{f.name}} = CleanedMemoryCache({ {{*f.args.map &.restriction}} }, Array({{typ}})).new

  {% for block in [true, false] %}
    def {% if f.receiver %}{{f.receiver}}.{% end %}{{f.name}}({{*f.args}}, expires_in : Time::Span) : Array({{typ}})
      @@cache_{{f.name}}.fetch({ {{*f.args.map &.internal_name}} }, expires_in: expires_in) do
        Array({{typ}}).new.tap do |result|
          {{f.name}}({{*f.args.map &.internal_name}}) do |item|
            result << {% if block %}yield{% end %} item
          end
        end
      end
    end
  {% end %}
end

class CleanedMemoryCache(K, V) < MemoryCache(K, V)
  class_getter cleanups = Array(->).new

  def initialize(*args, **kwargs)
    super
    @@cleanups << ->self.cleanup
  end
end

CronScheduler.define do
  at("0 19 * * *") do # every day 19:00
    CleanedMemoryCache.cleanups.each do |cleanup|
      cleanup.call
    end
  end
end
