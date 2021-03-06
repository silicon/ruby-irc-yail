require 'socket'
require 'thread'
require 'yaml'
require 'logger'

# To make this library seem smaller, a lot of code has been split up and put
# into semi-logical files.  I don't really like this hacky solution, but I
# cannot figure out a nicer way to keep the code as clean as I like.
require 'net/yail/magic_events'
require 'net/yail/default_events'
require 'net/yail/output_api'

# This tells us our version info.
require 'net/yail/yail-version'

# Finally, a real class to include!
require 'net/yail/event'

# If a thread crashes, I want the app to die.  My threads are persistent, not
# temporary.
Thread.abort_on_exception = true

module Net

# This library is based on the initial release of IRCSocket with a tiny bit
# of plagarism of Ruby-IRC.
#
# My aim here is to build something that is still fairly simple to use, but
# powerful enough to build a decent IRC program.
#
# This is far from complete, but it does successfully power a relatively
# complicated bot, so I believe it's solid and "good enough" for basic tasks.
#
# =Events
#
# * Register handlers by calling prepend_handler(symbol, method)
# * Events based on incoming data are represented by :incoming_*, while
#   outgoing are :outgoing_*
# * I'm still using the names from IRCSocket dev(s), so this means an incoming
#   message would call the :incoming_msg handler, and a message being sent
#   would call the :outgoing_msg handler.
#
# ==Incoming Events
#
# Current list of incoming events and the parameters sent to the handler:
# * :incoming_any(raw) - "global" handler that catches all events and may
#   modify their data as necessary before the real handler is hit.  This should
#   only be used in cases where it's necessary to grab a lot of events that
#   also need to be processed elsewhere, such as doing input filtering for
#   all events that have a "text" element.  Note that returning true from
#   this handler will still break the entire chain of event handling.
# * :incoming_msg(fullactor, actor, target, text) - Normal message from actor to target
# * :incoming_act(fullactor, actor, target, text) - CTCP "action" (emote) from actor to target
# * :incoming_invite(fullactor, actor, target) - INVITE to target channel from actor
# * :incoming_ctcp(fullactor, actor, target, text) - CTCP other than "action" from actor to target
# * :incoming_ctcpreply(fullactor, actor, target, text) - CTCP NOTICE from actor to target
# * :incoming_notice(fullactor, actor, target, text) - other NOTICE from actor to target
# * :incoming_mode(fullactor, actor, target, modes, objects) - actor sets modes on objects in target channel
# * :incoming_topic_change(fullactor, actor, channel, text) - actor sets channel topic to given text string
# * :incoming_join(fullactor, actor, target) - actor joins target channel
# * :incoming_part(fullactor, actor, target, text) - actor leaves target with message in text
# * :incoming_kick(fullactor, actor, target, object, text) - actor kicked object from target with reason 'text'
# * :incoming_quit(fullactor, actor, text) - actor left server completely with reason 'text'
# * :incoming_nick(fullactor, actor, nickname) - actor changed to nickname
# * :incoming_ping(text) - ping from server with given text
# * :incoming_miscellany(line) - text from server didn't match anything known
# * :incoming_welcome(text, args) - raw 001 from server, means we successfully logged in
# * :incoming_bannedfromchan(text, args) - banned from channel
# * Anything else in the eventmap.yml file with params(text, args).
#
# Common parameter elements:
# * fullactor: Rarely needed, full text of origin of an action
# * actor: Nickname of originator of an action
# * target: Nickname for private actions, channel name for public
# * text: Actual message/emote/notice/etc
# * args: For numeric handlers, this is a hash of :fullactor, :actor, and
#   :target.  Most numeric handlers I've built don't need this, so I made it
#   easier to just get what you specifically want.
#
# ==Outgoing Events
#
# Generally speaking, you won't need these very often, but they're here for
# the edge cases all the same.  Note that the socket output cannot be skipped
# (see "Return value from events" below), so this is truly just to allow
# modifying things before they go out (filtering speech, converting or
# stripping markup, etc) or just general stats-type logic.
#
# Note that in all cases below, the client is *about* to perform an action.
# Text can be filtered, things can be logged, but keep in mind that the action
# has not yet happened.
#
# Events:
# * :outgoing_begin_connection(username, address, realname) - called when the
#   start_listening method has set up all threading and such.  Default behavior
#   is to call user() and nick()
# * :outgoing_privmsg(target, text) - Any kind of PRIVMSG output is about to
#   get sent out
# * :outgoing_msg(target, text) - Hit by a direct call to msg, which is
#   normally used for "plain" messages, but a "clever" user could do their own
#   CTCP messages here as well.  Shoot them if they do.
# * :outgoing_ctcp(target, text) - All CTCP messages hit here eventually
# * :outgoing_act(target, text) - ACTION CTCP messages should go through this,
#   not manually use ctcp.
# * :outgoing_notice(target, text) - All NOTICE messages hit here
# * :outgoing_ctcpreply(target, text) - CTCP NOTICE messages
# * :outgoing_mode(target, modes, objects) - Sets or queries mode.  If modes is
#   present, sends mode list to target.  Objects would be users.
# * :outgoing_join(target, pass) - About to attempt to join target channel with
#   given password (pass is '' if not specified in the join() command)
# * :outgoing_part(target, text) - The given target channel is about to be
#   left, with optional text reason.
# * :outgoing_quit(text) - The client is about to quit, with optional text
#   reason.
# * :outgoing_nick(new_nick) - The client is about to change nickname
# * :outgoing_user(username, myaddress, address, realname) - We're about to
#   send a USER command.
# * :outgoing_pass(password) - The client is about to send a password to the
#   server via PASS.
# * :outgoing_oper(user, password) - The client is about to request ops from
#   the server via OPER.
# * :outgoing_topic(channel, new_topic) - If new_topic is blank (nil or ''),
#   the client is requesting the channel's topic, otherwise setting it.
# * :outgoing_names(channel) - Client is requesting a list of names in the
#   given channel, or all channels and names if channel is blank.
# * :outgoing_list(channel, server) - Client is querying channel information.
#   I honestly don't know what server is for from RFC, but asking for a
#   specific channel gives just data on that channel.
# * :outgoing_invite(nick, channel) - Client is sending an INVITE message to
#   nick for channel.
# * :outgoing_kick(nick, channel, comment) - Client is about to kick the user
#   from the channel with an optional comment.
#
# Note that a single output call can hit multiple handlers, so you must plan
# carefully.  A call to act() will hit the act handler, then ctcp (since act
# is a type of ctcp message), then privmsg.
#
# ==Custom Events
#
# Yes, you can register your own wacky event handlers if you like, and have
# your code call them.  Just register a handler with some funky name of
# your own design (avoid the prefixes :incoming and :outgoing for obvious
# reasons), and so long as something calls that handler, your handler method
# will get its data.
#
# This isn't likely useful for a simple program, but for a subclass or wrapper
# of the IRC class, having the ability to give *its* users new events without
# mucking up this class can be helpful.  For instance, see IRCBot#irc_loop
# and the :irc_loop event.  If one wants their bot to do something regularly,
# they just handle that event and get frequent calls.
#
# ==Return value from events
#
# The return can be *critical* - a true value tells the handlers to stop
# their chain (true = "yes, I handled this event, stay the frak away you
# other, lesser handlers!), so no other handlers will be called.  
# 
# Note that critical handlers (incoming ping, welcome, and nick change) cannot
# be overwritten as they actually run *before* user-defined handlers, and
# output handlers are just for filtering and cannot stop the socket from
# sending its data.  If you want to change that low-level stuff, you should
# subclass, modify the code directly, monkey-patch, or just write your own
# library.
#
# When should you return false from an event?  Generally any time you have a
# handler that really needs to report itself.  Unless you have multiple
# layers of handlers for a given event, there's little reason to worry about
# breaking the chain of events.  Since handlers are *prepended* to the list,
# anybody subclassing your code can override your events, not the other way
# around.  The main use is if you have multiple handlers for a single complex
# event, where you want each handler to do its own set process and pass on the
# event if it isn't resposible for that particular situation.  Allows complex
# interactions to be made a bit cleaner, theoretically.
#
# =Simple example
#
# For a program to do anything useful, it must instantiate an object with
# useful data and register some handlers:
#
#   require 'rubygems'
#   require 'net/yail'
#   
#   irc = Net::YAIL.new(
#     :address    => 'irc.server.com',
#     :username   => 'test',
#     :realname   => 'test name',
#     :nicknames  => ['test1', 'test2']
#   )
#   
#   # Get list of channels after MOTD is done
#   irc.prepend_handler :incoming_endofmotd, proc {|text, args|
#     irc.list
#     return false
#   }
#   
#   # When incoming channels are listed, print out the data
#   irc.prepend_handler :incoming_list, proc {|text, args|
#     puts "-------- got a channel: #{text}"
#     return false
#   }
#
#   irc.start_listening
#
#   # Loop forever!
#   while irc.dead_socket == false
#     # Avoid major CPU overuse by taking a very short nap
#     sleep 0.05
#   end
#   
#
# Now we've built a simple IRC listener that will connect to a (probably
# invalid) network, identify itself, and sit around waiting for the welcome
# message.  After this has occurred, we join a channel and return false.
#
# One could also define a method instead of a proc:
#
#   require 'rubygems'
#   require 'net/yail'
#
#   def welcome(text, args)
#     @irc.join('#channel')
#     return false
#   end
#
#   irc = Net::YAIL.new(
#     :address    => 'irc.someplace.co.uk',
#     :username   => 'Frakking Bot',
#     :realname   => 'John Botfrakker',
#     :nicknames  => ['bot1', 'bot2', 'bot3']
#   )
#
#   # Do our join immediately after we get the welcome message
#   irc.prepend_handler :incoming_welcome, method(:welcome)
#
#   # Listen for input and loop forever until CTRL+C is pressed
#   irc.start_listening!
#
# =Better example
#
# See the included logger bot (under the examples directory of this project)
# for use of the IRCBot base class.  It's a fully working bot example with
# real-world use.
class YAIL 
  include Net::IRCEvents::Magic
  include Net::IRCEvents::Defaults
  include Net::IRCOutputAPI

  attr_reader(
    :me,                # Nickname on the IRC server
    :registered,        # If true, we've been welcomed
    :nicknames,         # Array of nicknames to try when logging on to server
    :dead_socket,       # True if @socket.eof? or read/connect fail
    :socket             # TCPSocket instance
  )
  attr_accessor(
    :throttle_seconds,
    :log
  )

  def silent
    @log.warn '[DEPRECATED] - Net::YAIL#silent is deprecated as of 1.4.1'
    return @log_silent
  end
  def silent=(val)
    @log.warn '[DEPRECATED] - Net::YAIL#silent= is deprecated as of 1.4.1'
    @log_silent = val
  end

  def loud
    @log.warn '[DEPRECATED] - Net::YAIL#loud is deprecated as of 1.4.1'
    return @log_loud
  end
  def loud=(val)
    @log.warn '[DEPRECATED] - Net::YAIL#loud= is deprecated as of 1.4.1'
    @log_loud = val
  end

  # Makes a new instance, obviously.
  #
  # Note: I haven't done this everywhere, but for the constructor, I felt
  # it needed to have hash-based args.  It's just cleaner to me when you're
  # taking this many args.
  #
  # Options:
  # * <tt>:address</tt>: Name/IP of the IRC server
  # * <tt>:port</tt>: Port number, defaults to 6667
  # * <tt>:username</tt>: Username reported to server
  # * <tt>:realname</tt>: Real name reported to server
  # * <tt>:nicknames</tt>: Array of nicknames to cycle through
  # * <tt>:silent</tt>: DEPRECATED - Sets Logger level to FATAL and silences most non-Logger
  #   messages.
  # * <tt>:loud</tt>: DEPRECATED - Sets Logger level to DEBUG. Spits out too many messages for your own good,
  #   and really is only useful when debugging YAIL.  Defaults to false, thankfully.
  # * <tt>:throttle_seconds</tt>: Seconds between a cycle of privmsg sends.
  #   Defaults to 1.  One "cycle" is defined as sending one line of output to
  #   *all* targets that have output buffered.
  # * <tt>:server_password</tt>: Very optional.  If set, this is the password
  #   sent out to the server before USER and NICK messages.
  # * <tt>:log</tt>: Optional, if set uses this logger instead of the default (Ruby's Logger).
  #   If set, :loud and :silent options are ignored.
  # * <tt>:log_io</tt>: Optional, ignored if you specify your own :log - sends given object to
  #   Logger's constructor.  Must be filename or IO object.
  # * <tt>:use_ssl</tt>: Defaults to false.  If true, attempts to use SSL for connection.
  def initialize(options = {})
    @me                 = ''
    @nicknames          = options[:nicknames]
    @registered         = false
    @username           = options[:username]
    @realname           = options[:realname]
    @address            = options[:address]
    @port               = options[:port] || 6667
    @log_silent         = options[:silent] || false
    @log_loud           = options[:loud] || false
    @throttle_seconds   = options[:throttle_seconds] || 1
    @password           = options[:server_password]
    @ssl                = options[:use_ssl] || false

    # Special handling to avoid mucking with Logger constants if we're using a different logger
    if options[:log]
      @log = options[:log]
    else
      @log = Logger.new(options[:log_io] || STDERR)
      @log.level = Logger::WARN
 
      # Convert old-school options into logger stuff
      @log.level = Logger::DEBUG if @log_loud
      @log.level = Logger::FATAL if @log_silent
    end

    if (options[:silent] || options[:loud])
      @log.warn '[DEPRECATED] - passing :silent and :loud options to constructor are deprecated as of 1.4.1'
    end

    # Read in map of event numbers and names.  Yes, I stole this event map
    # file from RubyIRC and made very minor changes....  They stole it from
    # somewhere else anyway, so it's okay.
    eventmap = "#{File.dirname(__FILE__)}/yail/eventmap.yml"
    @event_number_lookup = File.open(eventmap) { |file| YAML::load(file) }.invert

    # We're not dead... yet...
    @dead_socket = false

    # Build our socket - if something goes wrong, it's immediately a dead socket.
    begin
      @socket = TCPSocket.new(@address, @port)
      setup_ssl if @ssl
    rescue StandardError => boom
      @log.fatal "+++ERROR: Unable to open socket connection in Net::YAIL.initialize: #{boom.inspect}"
      @dead_socket = true
      raise
    end

    # Shared resources for threads to try and coordinate....  I know very
    # little about thread safety, so this stuff may be a terrible disaster.
    # Please send me better approaches if you are less stupid than I.
    @input_buffer = []
    @input_buffer_mutex = Mutex.new
    @privmsg_buffer = {}
    @privmsg_buffer_mutex = Mutex.new

    # Buffered output is allowed to go out right away.
    @next_message_time = Time.now

    # Setup handlers
    @handlers = Hash.new
    setup_default_handlers
  end

  # Starts listening for input and builds the perma-threads that check for
  # input, output, and privmsg buffering.
  def start_listening
    # We don't want to spawn an extra listener
    return if Thread === @ioloop_thread

    # Don't listen if socket is dead
    return if @dead_socket

    # Exit a bit more gracefully than just crashing out - allow any :outgoing_quit filters to run,
    # and even give the server a second to clean up before we fry the connection
    #
    # TODO: perhaps this should be in a callback so user can override TERM/INT handling
    quithandler = lambda { quit('Terminated by user'); sleep 1; stop_listening; exit }
    trap("INT", quithandler)
    trap("TERM", quithandler)

    # Build forced / magic logic - welcome setting @me, ping response, etc.
    # Since we do these here, nobody can skip them and they're always first.
    setup_magic_handlers

    # Begin the listening thread
    @ioloop_thread = Thread.new {io_loop}
    @input_processor = Thread.new {process_input_loop}
    @privmsg_processor = Thread.new {process_privmsg_loop}

    # Let's begin the cycle by telling the server who we are.  This should
    # start a TERRIBLE CHAIN OF EVENTS!!!
    handle(:outgoing_begin_connection, @username, @address, @realname)
  end

  # This starts the connection, threading, etc. as start_listening, but *forces* the user into
  # and endless loop.  Great for a simplistic bot, but probably not universally desired.
  def start_listening!
    start_listening
    while !@dead_socket
      # This is more for CPU savings than actually needing a delay - CPU spikes if we never sleep
      sleep 0.05
    end
  end

  # Kills and clears all threads.  See note above about my lack of knowledge
  # regarding threads.  Please help me if you know how to make this system
  # better.  DEAR LORD HELP ME IF YOU CAN!
  def stop_listening
    return unless Thread === @ioloop_thread

    # Do thread-ending in a new thread or else we're liable to kill the
    # thread that's called this method
    Thread.new do
      # Kill all threads if they're really threads
      [@ioloop_thread, @input_processor, @privmsg_processor].each {|thread| thread.terminate if Thread === thread}

      @socket.close
      @socket = nil
      @dead_socket = true

      @ioloop_thread = nil
      @input_processor = nil
      @privmsg_processor = nil
    end
  end

  private

  # If user asked for SSL, this is where we set it all up
  def setup_ssl
    require 'openssl'
    ssl_context = OpenSSL::SSL::SSLContext.new()
    ssl_context.verify_mode = OpenSSL::SSL::VERIFY_NONE
    @socket = OpenSSL::SSL::SSLSocket.new(@socket, ssl_context)
    @socket.sync = true
    @socket.connect
  end

  # Depending on protocol (SSL vs. not), reads atomic messages from socket.  This could be the
  # start of more generic message reading for other protocols, but for now reads a single line
  # for IRC and any number of lines from SSL IRC.
  def read_socket_messages
    # Simple non-ssl socket == return a single line
    return [@socket.gets] unless @ssl

    # SSL socket == return all lines available
    return @socket.readpartial(Buffering::BLOCK_SIZE).split($/).collect {|message| message}
  end

  # Reads incoming data - should only be called by io_loop, and only when
  # we've already ensured that data is, in fact, available.
  def read_incoming_data
    begin
      messages = read_socket_messages.compact
    rescue StandardError => boom
      @dead_socket = true
      @log.fatal "+++ERROR in read_incoming_data -> @socket.gets: #{boom.inspect}"
      raise
    end

    # If we somehow got no data here, the socket is closed.  Run away!!!
    if !messages || messages.empty?
      @dead_socket = true
      return
    end

    # Chomp and push each message
    for message in messages
      message.chomp!
      @log.debug "+++INCOMING: #{message.inspect}"

      # Only synchronize long enough to push our incoming string onto the
      # input buffer
      @input_buffer_mutex.synchronize do
        @input_buffer.push(message)
      end
    end
  end

  # This should be called from a thread only!  Does nothing but listens
  # forever for incoming data, and calling handlers due to this listening
  def io_loop
    loop do
      # if no data is coming in, don't block the socket!
      read_incoming_data if Kernel.select([@socket], nil, nil, 0)

      # Check for dead socket
      @dead_socket = true if @socket.eof?

      sleep 0.05
    end
  end

  # This again is a thread-only method.  Loops forever, handling input
  # whenever the @input_buffer var has any.
  def process_input_loop
    lines = nil
    loop do
      # Only synchronize long enough to copy and clear the input buffer.
      @input_buffer_mutex.synchronize do
        lines = @input_buffer.dup
        @input_buffer.clear
      end

      if (lines)
        # Now actually handle the data we copied, secure in the knowledge
        # that our reader thread is no longer going to wait on us.
        while lines.empty? == false
          process_input(lines.shift)
        end

        lines = nil
      end

      sleep 0.05
    end
  end

  # Grabs one message for each target in the private message buffer, removing
  # messages from @privmsg_buffer.  Returns a hash array of target -> text
  def pop_privmsgs
    privmsgs = {}

    # Only synchronize long enough to pop the appropriate messages.  By
    # the way, this is UGLY!  I should really move some of this stuff....
    @privmsg_buffer_mutex.synchronize do
      for target in @privmsg_buffer.keys
        # Clean up our buffer to avoid a bunch of empty elements wasting
        # time and space
        if @privmsg_buffer[target].nil? || @privmsg_buffer[target].empty?
          @privmsg_buffer.delete(target)
          next
        end

        privmsgs[target] = @privmsg_buffer[target].shift
      end
    end

    return privmsgs
  end

  # Checks for new private messages, and outputs all that are gathered from
  # pop_privmsgs, if any
  def check_privmsg_output
    privmsgs = pop_privmsgs
    @next_message_time = Time.now + @throttle_seconds unless privmsgs.empty?

    for (target, out_array) in privmsgs
      report(out_array[1]) unless out_array[1].to_s.empty?
      raw("PRIVMSG #{target} :#{out_array.first}", false)
    end
  end

  # Our final thread loop - grabs the first privmsg for each target and
  # sends it on its way.
  def process_privmsg_loop
    loop do
      check_privmsg_output if @next_message_time <= Time.now && !@privmsg_buffer.empty?

      sleep 0.05
    end
  end

  # Gets some input, sends stuff off to a handler.  Yay.
  def process_input(line)
    # Allow global handler to break the chain, filter the line, whatever.  For
    # this release, it's a hack.  2.0 will be better.
    if (Array === @handlers[:incoming_any])
      for handler in @handlers[:incoming_any]
        result = handler.call(line)
        return if result == true
      end
    end

    # Use the exciting new-new parser
    event = Net::YAIL::IncomingEvent.parse(line)

    # Partial conversion to using events - we still have a horrible case statement, but
    # we're at least using the event object.  Slightly less hacky than before.

    # Except for this - we still have to handle numerics the crappy way until we build the proper
    # dispatching of events
    event = event.parent if event.parent && :incoming_numeric == event.parent.type

    case event.type
      # Ping is important to handle quickly, so it comes first.
      when :incoming_ping
        handle(event.type, event.text)

      when :incoming_numeric
        # Lovely - I passed in a "nick" - which, according to spec, is NEVER part of a numeric reply
        handle_numeric(event.numeric, event.servername, nil, event.target, event.text)

      when :incoming_invite
        handle(event.type, event.fullname, event.nick, event.channel)

      # Fortunately, the legacy handler for all five "message" types is the same!
      when :incoming_msg, :incoming_ctcp, :incoming_act, :incoming_notice, :incoming_ctcpreply
        # Legacy handling requires merger of target and channel....
        target = event.target if event.pm?
        target = event.channel if !target

        # Notices come from server sometimes, so... another merger for legacy fun!
        nick = event.server? ? '' : event.nick
        from = event.server? ? nick : event.from
        handle(event.type, from, nick, target, event.text)

      # This is a bit painful for right now - just use some hacks to make it work semi-nicely,
      # but let's not put hacks into the core Event object.  Modes need reworking soon anyway.
      #
      # NOTE: text is currently the mode settings ('+b', for instance) - very bad.  TODO: FIX FIX FIX!
      when :incoming_mode
        # Modes can come from the server, so legacy system again regularly sent nil data....
        nick = event.server? ? '' : event.nick
        handle(event.type, event.from, nick, event.channel, event.text, event.targets.join(' '))

      when :incoming_topic_change
        handle(event.type, event.fullname, event.nick, event.channel, event.text)

      when :incoming_join
        handle(event.type, event.fullname, event.nick, event.channel)

      when :incoming_part
        handle(event.type, event.fullname, event.nick, event.channel, event.text)

      when :incoming_kick
        handle(event.type, event.fullname, event.nick, event.channel, event.target, event.text)

      when :incoming_quit
        handle(event.type, event.fullname, event.nick, event.text)

      when :incoming_nick
        handle(event.type, event.fullname, event.nick, event.text)

      when :incoming_error
        handle(event.type, event.text)

      # Unknown line!
      else
        # This should really never happen, but isn't technically an error per se
        @log.warn 'Unknown line: %s!' % line.inspect
        handle(:incoming_miscellany, line)
    end
  end

  ##################################################
  # EVENT HANDLING ULTRA SUPERSYSTEM DELUXE!!!
  ##################################################

  public
  # Event handler hook.  Kinda hacky.  Calls your event(s) before the default
  # event.  Default stuff will happen if your handler doesn't return true.
  def prepend_handler(event, *procs, &block)
    raise "Cannot change handlers while threads are listening!" if @ioloop_thread

    # Allow blocks as well as procs
    if block_given?
      procs.push(block)
    end

    # See if this is a word for a numeric - only applies to incoming events
    if (event.to_s =~ /^incoming_(.*)$/)
      number = @event_number_lookup[$1].to_i
      event = :"incoming_numeric_#{number}" if number > 0
    end

    @handlers[event] ||= Array.new
    until procs.empty?
      @handlers[event].unshift(procs.pop)
    end
  end

  # Handles the given event (if it's in the @handlers array) with the
  # arguments specified.
  #
  # The @handlers must be a hash where key = event to handle and value is
  # a Proc object (via Class.method(:name) or just proc {...}).
  # This should be fine if you're setting up handlers with the prepend_handler
  # method, but if you get "clever," you're on your own.
  def handle(event, *arguments)
    # Don't bother with anything if there are no handlers registered.
    return unless Array === @handlers[event]

    @log.debug "+++EVENT HANDLER: Handling event #{event} via #{@handlers[event].inspect}:"

    # Call all hooks in order until one breaks the chain.  For incoming
    # events, we want something to break the chain or else it'll likely
    # hit a reporter.  For outgoing events, we tend to report them anyway,
    # so no need to worry about ending the chain except when the bot wants
    # to take full control over them.
    result = false
    for handler in @handlers[event]
      result = handler.call(*arguments)
      break if result == true
    end
  end

  # Since numerics are so many and so varied, this method will auto-fallback
  # to a simple report if no handler was defined.
  def handle_numeric(number, fullactor, actor, target, text)
    # All numerics share the same args, and rarely care about anything but
    # text, so let's make it easier by passing a hash instead of a list
    args = {:fullactor => fullactor, :actor => actor, :target => target}
    base_event = :"incoming_numeric_#{number}"
    if Array === @handlers[base_event]
      handle(base_event, text, args)
    else
      # No handler = report and don't worry about it
      @log.info "Unknown raw #{number.to_s} from #{fullactor}: #{text}"
    end
  end

  # Reports may not get printed in the proper order since I scrubbed the
  # IRCSocket report capturing, but this is way more straightforward to me.
  def report(*lines)
    lines.each {|line| $stdout.puts "(#{Time.now.strftime('%H:%M.%S')}) #{line}"}
  end
end

end
