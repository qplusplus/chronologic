require 'active_support/core_ext/hash'

class Chronologic::Client::Fake

  attr_reader :objects, :subscribers, :events, :timelines

  def initialize
    @objects = {}
    @subscribers = Hash.new { |hsh, k| hsh[k] = {} }
    @events = {}
    @timelines = Hash.new { |hsh, k| hsh[k] = {} }
  end

  def record(object_key, data)
    raise ArgumentError.new("`data` should be a Hash.") unless data.is_a?(Hash)
    @objects[object_key] = data
  end

  def unrecord(object_key)
    @objects.delete(object_key)
  end

  def subscribe(subscriber_key, timeline_key, backlink_key=nil, backfill=true)
    @subscribers[subscriber_key][timeline_key] = backlink_key
    # TODO: backfill
  end

  def unsubscribe(subscriber_key, timeline_key)
    @subscribers[subscriber_key].delete(timeline_key)
    # TODO: unfill
  end

  def connected?(subscriber_key, backlink_key)
    @subscribers[subscriber_key].values.include?(backlink_key)
  end

  def publish(e)
    raise ArgumentError.new("`event` should be a Chronologic::Client::Event.") unless e.is_a?(Chronologic::Client::Event)

    event = service_event_for(e)
    event.key = e.key

    @events[event.key] = event
    event.timelines.each do |timeline|
      @timelines[timeline][event.token] = event.key
      @subscribers[timeline].keys.each do |t|
        @timelines[t][event.token] = event.key
      end
    end

    event.key
  end

  def unpublish(event_key)
    @events.delete(event_key)
    # XXX unfanout
  end

  def fetch(event_url)
    event = @events[event_url]
    return event if event.nil?
    event.dup.tap do |event|
      populate_subevents_for(event)
      populate_objects_for(event)
    end
    client_event_for(event)
  end

  def update(event, update_timelines=false)
    @events[event.key] = event
    # XXX update timelines
  end

  def timeline(timeline_key, options={})
    per_page = options.fetch('per_page', 10)
    page = options.fetch('page', -1)

    range =
      # Fetch the timeline
      @timelines[timeline_key].
        # Convert the token -> event key mapping to an array
        to_a.
        # Only use events greater than the paging token
        select { |(k, v)| k.to_i >= page }.
        # Sort by the token
        sort_by { |k, v| k }.
        # Put it in reverse chronologic order
        reverse

    # Grab n entries out of the range, take the last one, and grab its token
    next_page = range.first(per_page).last.first
    count = @timelines[timeline_key].length

    # Reverse the range (?), grab n entries, take just the value
    event_keys = range.reverse.first(per_page).map { |k, v| v }
    items = event_keys.map { |k| @events[k] }

    items.each do |ev|
      populate_objects_for(ev)
      populate_subevents_for(ev)
    end

    {
      "items"     => items,
      "count"     => count,
      "next_page" => next_page.to_i
    }
  end

  # Private
  def populate_objects_for(event)
    # At this point, objects is a hash of key -> array pairs. We need key -> hash.
    objects = Hash.new { |hsh, k| hsh[k] = Hash.new }
    event.objects.each do |k, refs|
      refs.each { |ref| objects[k][ref] = @objects[ref] }
    end
    event.objects = objects
  end

  # Private
  def populate_subevents_for(event)
    subevents = @timelines[event.key].values.map do |event_key|
      fetch(event_key)
    end
    event.subevents = subevents
  end

  # Private
  def client_event_for(event)
    Chronologic::Client::Event.from_attributes({
      "key" => event.key,
      "data" => event.data,
      "objects" => event.objects,
      "timelines" => event.timelines,
      "subevents" => event.subevents.map { |e| client_event_for(e) }
    })
  end

  # Private
  def service_event_for(event)
    Chronologic::Service::Event.from_columns(event.to_transport)
  end

end
