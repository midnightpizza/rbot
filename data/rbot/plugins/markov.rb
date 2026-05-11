#-- vim:sw=2:et
#++
#
# :title: Markov plugin
#
# Author:: Tom Gilbert <tom@linuxbrit.co.uk>
# Copyright:: (C) 2005 Tom Gilbert
#
# Contribute to chat with random phrases built from word sequences learned
# by listening to chat

class MarkovPlugin < Plugin
  Config.register Config::BooleanValue.new('markov.enabled',
    :default => false,
    :desc => "Enable and disable the plugin")
  Config.register Config::IntegerValue.new('markov.probability',
    :default => 25,
    :validate => Proc.new { |v| (0..100).include? v },
    :desc => "Percentage chance of markov plugin chipping in")
  Config.register Config::ArrayValue.new('markov.ignore',
    :default => [],
    :desc => "Hostmasks and channel names markov should NOT learn from (e.g. idiot*!*@*, #privchan).")
  Config.register Config::ArrayValue.new('markov.readonly',
    :default => [],
    :desc => "Hostmasks and channel names markov should NOT talk to (e.g. idiot*!*@*, #privchan).")
  Config.register Config::IntegerValue.new('markov.max_words',
    :default => 50,
    :validate => Proc.new { |v| (0..100).include? v },
    :desc => "Maximum number of words the bot should put in a sentence")
  Config.register Config::FloatValue.new('markov.learn_delay',
    :default => 0.5,
    :validate => Proc.new { |v| v >= 0 },
    :desc => "Time the learning thread spends sleeping after learning a line. If set to zero, learning from files can be very CPU intensive, but also faster.")
  Config.register Config::IntegerValue.new('markov.delay',
    :default => 5,
    :validate => Proc.new { |v| v >= 0 },
    :desc => "Wait short time before contributing to conversation.")
  Config.register Config::IntegerValue.new('markov.answer_addressed',
    :default => 50,
    :validate => Proc.new { |v| (0..100).include? v },
    :desc => "Probability of answer when addressed by nick")
  Config.register Config::ArrayValue.new('markov.ignore_patterns',
    :default => [],
    :desc => "Ignore these word patterns")
  Config.register Config::FloatValue.new('markov.temperature',
    :default => 0.35,
    :validate => Proc.new { |v| v > 0 && v <= 1 },
    :desc => "Temperature for word selection: lower = more predictable, higher = more random")
  Config.register Config::IntegerValue.new('markov.history_size',
    :default => 10,
    :validate => Proc.new { |v| v >= 0 },
    :desc => "Number of previous messages to remember per channel for fallback generation")
  Config.register Config::IntegerValue.new('markov.history_use_probability',
    :default => 70,
    :validate => Proc.new { |v| (0..100).include? v },
    :desc => "Probability (0-100) of using history fallback when normal generation fails")

  MARKER = :"\r\n"


  def initialize
    super
    @registry.set_default([])
    if @registry.has_key?('enabled')
      @bot.config['markov.enabled'] = @registry['enabled']
      @registry.delete('enabled')
    end
    if @registry.has_key?('probability')
      @bot.config['markov.probability'] = @registry['probability']
      @registry.delete('probability')
    end
    if @bot.config['markov.ignore_users']
      debug "moving markov.ignore_users to markov.ignore"
      @bot.config['markov.ignore'] = @bot.config['markov.ignore_users'].dup
      @bot.config.delete('markov.ignore_users'.to_sym)
    end

    # In‑memory hashes (empty at first)
    @chains = {}
    @rchains = {}
    @chains_mutex = Mutex.new
    @rchains_mutex = Mutex.new

    if @registry.has_key?('chains_backup')
      begin
        data = @registry['chains_backup']
        if data.is_a?(Hash)
          @chains = data['chains'] || data[:chains] || {}
          @rchains = data['rchains'] || data[:rchains] || {}
          log "Loaded Markov chains from chains_backup (#{@chains.size} forward, #{@rchains.size} reverse)"
        end
      rescue => e
        error "Failed to load chains_backup: #{e.message}"
      end
    end

    @learning_queue = Queue.new
    @learning_thread = Thread.new do
      while s = @learning_queue.pop
        begin
          learn_line s
        rescue => e
          error "Learning error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        end
        sleep @bot.config['markov.learn_delay'] unless @bot.config['markov.learn_delay'].zero?
      end
    end
    @learning_thread.priority = -1

    # Periodic save
    @save_timer = @bot.timer.add(30) { save_chains }

    # History buffer
    @history = {}
    @history_mutex = Mutex.new
  end


  def cleanup
    @bot.timer.remove(@save_timer) if @save_timer

    debug 'closing learning thread'
    @learning_queue.clear
    @learning_queue.push nil
    @learning_thread.join
    debug 'learning thread closed'

    # Final save
    save_chains
    super
  end

  # Persist in‑memory chains to a single registry key
  def save_chains
    data = {}
    @chains_mutex.synchronize { data['chains'] = @chains.dup }
    @rchains_mutex.synchronize { data['rchains'] = @rchains.dup }
    @registry['chains_backup'] = data
    debug "Markov chains saved (#{@chains.size} forward, #{@rchains.size} reverse)"
  rescue => e
    error "Failed to save Markov chains: #{e.message}"
  end

  # pick a word from the in‑memory chain
  def pick_word(word1, word2, chainz=@chains)
    k = "#{word1} #{word2}"
    return MARKER unless chainz.key? k
    pick_word_from_list(chainz[k])
  end

  # pick a word from weighted hash with temperature scaling
  def pick_word_from_list(wordlist)
    total = wordlist.first
    hash = wordlist.last
    return MARKER if total == 0
    return hash.keys.first if hash.length == 1

    temperature = @bot.config['markov.temperature']
    if temperature != 1.0
      weights = hash.values.map { |w| w ** (1.0 / temperature) }
      sum = weights.sum
      r = rand
      cumulative = 0.0
      hash.keys.each_with_index do |k, i|
        cumulative += weights[i] / sum
        return k if r < cumulative
      end
    else
      hit = rand(total)
      hash.each do |k, w|
        hit -= w
        return k if hit < 0
      end
    end
    MARKER
  end

  # Generate a completely random sentence
  def generate_random_sentence
    word1, word2 = MARKER, MARKER
    output = []
    @bot.config['markov.max_words'].times do
      word3 = pick_word(word1, word2)
      break if word3 == MARKER
      output << word3
      word1, word2 = word2, word3
    end
    return nil if output.length < 3
    sentence = output.join(' ')
    sentence[0] = sentence[0].capitalize
    sentence << '.' unless sentence =~ /[.!?]$/
    sentence
  end

  # Generate from an exact two‑word seed
  def generate_from_pair(w1, w2)
    key = "#{w1} #{w2}"
    return nil unless @chains.key?(key)
    output = [w1, w2]
    while output.length < @bot.config['markov.max_words'] && output.last != MARKER
      nxt = pick_word(output[-2], output[-1])
      break if nxt == MARKER
      output << nxt
    end
    output.delete(MARKER)
    return nil if output.length < 3
    sentence = output.join(' ')
    sentence[0] = sentence[0].capitalize
    sentence << '.' unless sentence =~ /[.!?]$/
    sentence
  end

  # Generate a sentence containing a specific word
  def generate_containing_word(word)
    candidates = []
    @chains.each_key do |key|
      if key =~ /^#{Regexp.escape(word)} /
        w2 = key.split[1]
        candidates << w2 unless w2 == MARKER
      end
    end
    candidates.uniq!
    return nil if candidates.empty?
    w2 = candidates.sample
    generate_from_pair(word, w2)
  end

  # Fallback: use channel history
  def generate_from_history(channel, seed_words)
    return nil unless channel && @history[channel] && !@history[channel].empty?
    seeds = seed_words.is_a?(Array) ? seed_words : [seed_words]
    seeds.compact!
    return nil if seeds.empty?

    candidates = @history[channel].select do |msg|
      seeds.any? { |s| msg.downcase.include?(s.downcase) }
    end
    return nil if candidates.empty?

    hist_msg = candidates.sample
    words = hist_msg.split(/\s+/).reject { |w| w.length < 3 }
    return nil if words.length < 2

    pairs = seq_pairs(words).sort_by { rand }
    pairs.each do |w1, w2|
      sentence = generate_from_pair(w1, w2)
      return sentence if sentence
    end
    words.sort_by { rand }.each do |w|
      sentence = generate_containing_word(w)
      return sentence if sentence
    end
    nil
  end

  # Main generation method with fallbacks
  def generate_string(channel, word1, word2=nil)
    if word2
      sentence = generate_from_pair(word1, word2)
      return sentence if sentence
      sentence = generate_containing_word(word1) || generate_containing_word(word2)
      return sentence if sentence
      if rand(100) < @bot.config['markov.history_use_probability']
        sentence = generate_from_history(channel, [word1, word2])
        return sentence if sentence
      end
      return generate_random_sentence
    end

    sentence = generate_containing_word(word1)
    return sentence if sentence
    if rand(100) < @bot.config['markov.history_use_probability']
      sentence = generate_from_history(channel, word1)
      return sentence if sentence
    end
    generate_random_sentence
  end

  def help(plugin, topic = '')
    topic, subtopic = topic.split

    case topic
    when "delay"
      "markov delay <value> => Set message delay"
    when "ignore"
      case subtopic
      when "add"
        "markov ignore add <hostmask|channel> => ignore a hostmask or a channel"
      when "list"
        "markov ignore list => show ignored hostmasks and channels"
      when "remove"
        "markov ignore remove <hostmask|channel> => unignore a hostmask or channel"
      else
        "ignore hostmasks or channels -- topics: add, remove, list"
      end
    when "readonly"
      case subtopic
      when "add"
        "markov readonly add <hostmask|channel> => read-only a hostmask or a channel"
      when "list"
        "markov readonly list => show read-only hostmasks and channels"
      when "remove"
        "markov readonly remove <hostmask|channel> => unreadonly a hostmask or channel"
      else
        "restrict hostmasks or channels to read only -- topics: add, remove, list"
      end
    when "status"
      "markov status => show if markov is enabled, probability and amount of messages in queue for learning"
    when "probability"
      "markov probability [<percent>] => set the % chance of rbot responding to input, or display the current probability"
    when "temperature"
      "markov temperature [<value>] => set randomness (0.2-0.5 = coherent, 1.0 = random)"
    when "chat"
      case subtopic
      when "about"
        "markov chat about <word> [<another word>] => talk about <word> or riff on a word pair (if possible)"
      else
        "markov chat => try to say something intelligent"
      end
    when "learn"
      ["markov learn from <file> [testing [<num> lines]] [using pattern <pattern>]:",
       "learn from the text in the specified <file>, optionally using the given <pattern> to filter the text.",
       "you can sample what would be learned by specifying 'testing <num> lines'"].join(' ')
    else
      "markov plugin: listens to chat to build a markov chain, with which it can (perhaps) attempt to (inanely) contribute to 'discussion'. Sort of.. Will get a *lot* better after listening to a lot of chat. Usage: 'chat' to attempt to say something relevant to the last line of chat, if it can -- help topics: ignore, readonly, delay, status, probability, temperature, chat, chat about, learn"
    end
  end

  def clean_message(m)
    str = m.plainmessage.dup
    str =~ /^(\S+)([:,;])/
    if $1 and m.target.is_a? Irc::Channel and m.target.user_nicks.include? $1.downcase
      str.gsub!(/^(\S+)([:,;])\s+/, "")
    end
    str.gsub!(/\s{2,}/, ' ')
    return str.strip
  end

  def probability?
    return @bot.config['markov.probability']
  end

  def status(m,params)
    if @bot.config['markov.enabled']
      reply = _("markov is currently enabled, %{p}%% chance of chipping in") % { :p => probability? }
      l = @learning_queue.length
      reply << (_(", %{l} messages in queue") % {:l => l}) if l > 0
    else
      reply = _("markov is currently disabled")
    end
    m.reply reply
  end

  def ignore?(m=nil)
    return false unless m
    return true if m.private?
    return true if m.prefixed?
    @bot.config['markov.ignore'].each do |mask|
      return true if m.channel.downcase == mask.downcase
      return true if m.source.matches?(mask)
    end
    return false
  end

  def readonly?(m=nil)
    return false unless m
    @bot.config['markov.readonly'].each do |mask|
      return true if m.channel.downcase == mask.downcase
      return true if m.source.matches?(mask)
    end
    return false
  end

  def ignore(m, params)
    action = params[:action]
    user = params[:option]
    case action
    when 'remove'
      if @bot.config['markov.ignore'].include? user
        s = @bot.config['markov.ignore']
        s.delete user
        @bot.config['ignore'] = s
        m.reply _("%{u} removed") % { :u => user }
      else
        m.reply _("not found in list")
      end
    when 'add'
      if user
        if @bot.config['markov.ignore'].include?(user)
          m.reply _("%{u} already in list") % { :u => user }
        else
          @bot.config['markov.ignore'] = @bot.config['markov.ignore'].push user
          m.reply _("%{u} added to markov ignore list") % { :u => user }
        end
      else
        m.reply _("give the name of a person or channel to ignore")
      end
    when 'list'
      m.reply _("I'm ignoring %{ignored}") % { :ignored => @bot.config['markov.ignore'].join(", ") }
    else
      m.reply _("have markov ignore the input from a hostmask or a channel. usage: markov ignore add <mask or channel>; markov ignore remove <mask or channel>; markov ignore list")
    end
  end

  def readonly(m, params)
    action = params[:action]
    user = params[:option]
    case action
    when 'remove'
      if @bot.config['markov.readonly'].include? user
        s = @bot.config['markov.readonly']
        s.delete user
        @bot.config['markov.readonly'] = s
        m.reply _("%{u} removed") % { :u => user }
      else
        m.reply _("not found in list")
      end
    when 'add'
      if user
        if @bot.config['markov.readonly'].include?(user)
          m.reply _("%{u} already in list") % { :u => user }
        else
          @bot.config['markov.readonly'] = @bot.config['markov.readonly'].push user
          m.reply _("%{u} added to markov readonly list") % { :u => user }
        end
      else
        m.reply _("give the name of a person or channel to read only")
      end
    when 'list'
      m.reply _("I'm only reading %{readonly}") % { :readonly => @bot.config['markov.readonly'].join(", ") }
    else
      m.reply _("have markov not answer to input from a hostmask or a channel. usage: markov readonly add <mask or channel>; markov readonly remove <mask or channel>; markov readonly list")
    end
  end

  def enable(m, params)
    @bot.config['markov.enabled'] = true
    m.okay
  end

  def probability(m, params)
    if params[:probability]
      @bot.config['markov.probability'] = params[:probability].to_i
      m.okay
    else
      m.reply _("markov has a %{prob}%% chance of chipping in") % { :prob => probability? }
    end
  end

  def set_temperature(m, params)
    if params[:temperature]
      temp = params[:temperature].to_f
      if temp > 0 && temp <= 1
        @bot.config['markov.temperature'] = temp
        m.okay
      else
        m.reply _("Temperature must be between 0 and 1 (exclusive 0).")
      end
    else
      m.reply _("Current temperature: %{t} (lower = more predictable, higher = more random)") % { :t => @bot.config['markov.temperature'] }
    end
  end

  def disable(m, params)
    @bot.config['markov.enabled'] = false
    m.okay
  end

  def should_talk(m)
    return false unless @bot.config['markov.enabled']
    prob = m.address? ? @bot.config['markov.answer_addressed'] : probability?
    return true if prob > rand(100)
    return false
  end

  def seq_pairs(arr)
    res = []
    0.upto(arr.size-2) do |i|
      res << [arr[i], arr[i+1]]
    end
    res
  end

  def set_delay(m, params)
    if params[:delay] == "off"
      @bot.config["markov.delay"] = 0
      m.okay
    elsif !params[:delay]
      m.reply _("Message delay is %{delay}" % { :delay => @bot.config["markov.delay"]})
    else
      @bot.config["markov.delay"] = params[:delay].to_i
      m.okay
    end
  end

  def reply_delay(m, line)
    m.replied = true
    if @bot.config['markov.delay'] > 0
      @bot.timer.add_once(1 + rand(@bot.config['markov.delay'])) {
        m.reply line, :nick => false, :to => :public
      }
    else
      m.reply line, :nick => false, :to => :public
    end
  end

  def update_history(channel, message)
    return unless channel && channel.is_a?(String)
    @history_mutex.synchronize do
      @history[channel] ||= []
      @history[channel] << message
      max_size = @bot.config['markov.history_size']
      if @history[channel].size > max_size
        @history[channel] = @history[channel].last(max_size)
      end
    end
  end

  def random_markov(m, message)
    return unless should_talk(m)

    words = clean_message(m).split(/\s+/)
    channel = m.channel if m.target.is_a?(Irc::Channel)

    if words.length >= 2
      pairs = seq_pairs(words).sort_by { rand }
      pairs.each do |word1, word2|
        line = generate_string(channel, word1, word2)
        if line && line != message && !message.index(line)
          reply_delay m, line
          return
        end
      end
    end

    words.sort_by { rand }.each do |word|
      line = generate_string(channel, word)
      if line && line != message && !message.index(line)
        reply_delay m, line
        return
      end
    end

    line = generate_random_sentence
    if line && line != message
      reply_delay m, line
    end
  rescue => e
    error "Error in random_markov: #{e.message}"
  end

  def chat(m, params)
    channel = m.channel if m.target.is_a?(Irc::Channel)
    line = generate_string(channel, params[:seed1], params[:seed2])
    if line
      m.reply line
    else
      m.reply _("I can't think of anything right now.")
    end
  end

  def rand_chat(m, params)
    line = generate_random_sentence
    if line
      m.reply line
    else
      m.reply _("I can't :(")
    end
  end

  def learn(*lines)
    lines.each { |l| @learning_queue.push l }
  end

  def unreplied(m)
    return if ignore? m

    message = m.plainmessage
    if m.action?
      message = "#{m.sourcenick} #{message}"
    end

    if m.target.is_a?(Irc::Channel) && !ignore?(m)
      update_history(m.channel, clean_message(m))
    end

    random_markov(m, message) unless readonly? m or m.replied?
    learn clean_message(m)
  end

  # Learn a triplet into the in‑memory hash (fast, thread‑safe)
  def learn_triplet(word1, word2, word3)
    k = "#{word1} #{word2}"
    rk = "#{word2} #{word3}"

    @chains_mutex.synchronize do
      total = 0
      hash = Hash.new(0)
      if @chains.key?(k)
        t2, h2 = @chains[k]
        total += t2
        hash.update h2
      end
      hash[word3] += 1
      total += 1
      @chains[k] = [total, hash]
    end

    @rchains_mutex.synchronize do
      total = 0
      hash = Hash.new(0)
      if @rchains.key?(rk)
        t2, h2 = @rchains[rk]
        total += t2
        hash.update h2
      end
      hash[word1] += 1
      total += 1
      @rchains[rk] = [total, hash]
    end
  end

  def learn_line(message)
    wordlist = message.strip.split(/\s+/).reject do |w|
      @bot.config['markov.ignore_patterns'].map do |pat|
        w =~ Regexp.new(pat.to_s)
      end.select{|v| v}.size != 0
    end
    return unless wordlist.length >= 2
    word1, word2 = MARKER, MARKER
    wordlist << MARKER
    wordlist.each do |word3|
      learn_triplet(word1, word2, word3.to_sym)
      word1, word2 = word2, word3
    end
  end

  def learn_from(m, params)
    begin
      path = params[:file]
      file = File.open(path, "r")
      pattern = params[:pattern].empty? ? nil : Regexp.new(params[:pattern].to_s)
    rescue Errno::ENOENT
      m.reply _("no such file")
      return
    end

    if file.eof?
      m.reply _("the file is empty!")
      return
    end

    if params[:testing]
      lines = []
      range = case params[:lines]
      when /^\d+\.\.\d+$/
        Range.new(*params[:lines].split("..").map { |e| e.to_i })
      when /^\d+$/
        Range.new(1, params[:lines].to_i)
      else
        Range.new(1, [@bot.config['send.max_lines'], 3].max)
      end

      file.each do |line|
        next unless file.lineno >= range.begin
        lines << line.chomp
        break if file.lineno == range.end
      end

      lines = lines.map do |l|
        pattern ? l.scan(pattern).to_s : l
      end.reject { |e| e.empty? }

      if pattern
        unless lines.empty?
          m.reply _("example matches for that pattern at lines %{range} include: %{lines}") % {
            :lines => lines.map { |e| Underline+e+Underline }.join(", "),
            :range => range.to_s
          }
        else
          m.reply _("the pattern doesn't match anything at lines %{range}") % {
            :range => range.to_s
          }
        end
      else
        m.reply _("learning from the file without a pattern would learn, for example: ")
        lines.each { |l| m.reply l }
      end

      return
    end

    if pattern
      file.each { |l| learn(l.scan(pattern).to_s) }
    else
      file.each { |l| learn(l.chomp) }
    end

    m.okay
  end

  def stats(m, params)
    m.reply "Markov status: chains: #{@chains.length} forward, #{@rchains.length} reverse, queued phrases: #{@learning_queue.size}"
  end

end

plugin = MarkovPlugin.new
plugin.map 'markov delay :delay', :action => "set_delay"
plugin.map 'markov delay', :action => "set_delay"
plugin.map 'markov ignore :action :option', :action => "ignore"
plugin.map 'markov ignore :action', :action => "ignore"
plugin.map 'markov ignore', :action => "ignore"
plugin.map 'markov readonly :action :option', :action => "readonly"
plugin.map 'markov readonly :action', :action => "readonly"
plugin.map 'markov readonly', :action => "readonly"
plugin.map 'markov enable', :action => "enable"
plugin.map 'markov disable', :action => "disable"
plugin.map 'markov status', :action => "status"
plugin.map 'markov stats', :action => "stats"
plugin.map 'markov temperature [:temperature]', :action => 'set_temperature',
           :defaults => { :temperature => nil },
           :requirements => { :temperature => /^\d+(?:\.\d+)?$/ }
plugin.map 'chat about :seed1 [:seed2]', :action => "chat", :defaults => {:seed2 => nil}
plugin.map 'chat', :action => "rand_chat"
plugin.map 'markov probability [:probability]', :action => "probability",
           :defaults => {:probability => nil},
           :requirements => {:probability => /^\d+%?$/}
plugin.map 'markov learn from :file [:testing [:lines lines]] [using pattern *pattern]', :action => "learn_from", :thread => true,
           :requirements => {
             :testing => /^testing$/,
             :lines   => /^(?:\d+\.\.\d+|\d+)$/ }

plugin.default_auth('ignore', false)
plugin.default_auth('probability', false)
plugin.default_auth('learn', false)