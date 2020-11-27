require "athena"

macro view(typ)
  @[ADI::Register]
  struct {{typ}}Listener
    include AED::EventListenerInterface

    def self.subscribed_events : AED::SubscribedEvents
      AED::SubscribedEvents{ART::Events::View => 100}
    end

    def call(event : ART::Events::View, dispatcher : AED::EventDispatcherInterface) : Nil
      if (result = event.action_result.as?(Result))
        event.response = {{yield}}
      end
    end
  end
end

HTML_HEADERS = HTTP::Headers{"content-type" => MIME.from_extension(".html")}
