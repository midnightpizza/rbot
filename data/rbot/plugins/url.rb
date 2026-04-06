#-- vim:sw=2:et
#++
#
# :title: Url plugin

require 'socket'
require 'net/http'
require 'uri'
require 'zlib'
require 'stringio'
require 'webrick/cookie'

define_structure :Url, :channel, :nick, :time, :url, :info

class UrlPlugin < Plugin
  LINK_INFO = "[Link Info]"
  OUR_UNSAFE = Regexp.new("[^#{URI::PATTERN::UNRESERVED}#{URI::PATTERN::RESERVED}%# ]", false, 'N')
  USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  Config.register Config::IntegerValue.new('url.max_urls',
    :default => 100, :validate => Proc.new{|v| v > 0},
    :desc => "Maximum number of urls to store. New urls replace oldest ones.")
  Config.register Config::IntegerValue.new('url.display_link_info',
    :default => 0,
    :desc => "Get the title of links pasted to the channel and display it (also tells if the link is broken or the site is down). Do it for at most this many links per line (set to 0 to disable)")
  Config.register Config::BooleanValue.new('url.auto_shorten',
    :default => false,
    :desc => "Automatically spit out shortened URLs when they're seen. Check shortenurls for config options")
  Config.register Config::IntegerValue.new('url.auto_shorten_min_length',
    :default => 48,
    :desc => "Minimum length of URL to auto-shorten.  Only has an effect when url.auto_shorten is true.")
  Config.register Config::BooleanValue.new('url.titles_only',
    :default => false,
    :desc => "Only show info for links that have <title> tags (in other words, don't display info for jpegs, mpegs, etc.)")
  Config.register Config::BooleanValue.new('url.first_par',
    :default => false,
    :desc => "Also try to get the first paragraph of a web page")
  Config.register Config::IntegerValue.new('url.first_par_length',
    :default => 150,
    :desc => "The max length of the first paragraph")
  Config.register Config::ArrayValue.new('url.first_par_whitelist',
    :default => ['twitter.com'],
    :desc => "List of url patterns to show the content for.")
  Config.register Config::BooleanValue.new('url.info_on_list',
    :default => false,
    :desc => "Show link info when listing/searching for urls")
  Config.register Config::ArrayValue.new('url.no_info_hosts',
    :default => ['localhost', '^192\.168\.', '^10\.', '^127\.', '^172\.(1[6-9]|2\d|31)\.'],
    :on_change => Proc.new { |bot, v| bot.plugins['url'].reset_no_info_hosts },
    :desc => "A list of regular expressions matching hosts for which no info should be provided")
  Config.register Config::ArrayValue.new('url.only_on_channels',
    :desc => "Show link info only on these channels",
    :default => [])
  Config.register Config::ArrayValue.new('url.ignore',
    :desc => "Don't show link info for urls from users represented as hostmasks on this list. Useful for ignoring other bots, for example.",
    :default => [])

  def initialize
    super
    @registry.set_default(Array.new)
    unless @bot.config['url.display_link_info'].kind_of?(Integer)
      @bot.config.items[:'url.display_link_info'].set_string(@bot.config['url.display_link_info'].to_s)
    end
    reset_no_info_hosts
    self.filter_group = :htmlinfo
    load_filters
  end

  def reset_no_info_hosts
    @no_info_hosts = Regexp.new(@bot.config['url.no_info_hosts'].join('|'), true)
    debug "no info hosts regexp set to #{@no_info_hosts}"
  end

  def help(plugin, topic = '')
    "url info <url> => display link info for <url> (set url.display_link_info > 0 if you want the bot to do it automatically when someone writes an url), urls [<max>=4] => list <max> last urls mentioned in current channel, urls search [<max>=4] <regexp> => search for matching urls. In a private message, you must specify the channel to query, eg. urls <channel> [max], urls search <channel> [max] <regexp>"
  end

 def robust_fetch(url_str, redirect_limit = 5, cookie_jar = {})
  raise "Too many redirects" if redirect_limit == 0

  uri = URI.parse(url_str)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')
  http.open_timeout = 10
  http.read_timeout = 10
  http.ssl_version = :TLSv1_2 if http.use_ssl?

  request = Net::HTTP::Get.new(uri.request_uri)

  request['User-Agent'] = USER_AGENT
  request['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8'
  request['Accept-Language'] = 'en-US,en;q=0.9'
  request['Accept-Encoding'] = 'gzip, deflate, br'
  request['Connection'] = 'keep-alive'
  request['Upgrade-Insecure-Requests'] = '1'
  request['Sec-Fetch-Dest'] = 'document'
  request['Sec-Fetch-Mode'] = 'navigate'
  request['Sec-Fetch-Site'] = 'none'
  request['Sec-Fetch-User'] = '?1'
  request['Cache-Control'] = 'max-age=0'
  request['Referer'] = "https://www.google.com/"

  unless cookie_jar.empty?
    cookie_header = cookie_jar.map { |name, value| "#{name}=#{value}" }.join('; ')
    request['Cookie'] = cookie_header
  end

  response = http.request(request)

  if response['Set-Cookie']
    require 'webrick/cookie' unless defined?(WEBrick::Cookie)
    cookies = WEBrick::Cookie.parse(response['Set-Cookie'])
    cookies.each do |cookie|
      cookie_jar[cookie.name] = cookie.value
    end
  end

  # Handle redirects
  if response.is_a?(Net::HTTPRedirection)
    location = response['location']
    new_uri = URI.parse(location)
    new_uri = uri.merge(new_uri) if new_uri.relative?
    return robust_fetch(new_uri.to_s, redirect_limit - 1, cookie_jar)
  end

  unless response.is_a?(Net::HTTPSuccess)
    raise "#{response.code} - #{response.message}"
  end

  body = response.body

  # Decompress the response body based on Content-Encoding
  case response['content-encoding']
  when 'gzip'
    body = Zlib::GzipReader.new(StringIO.new(body)).read
  when 'deflate'
    body = Zlib::Inflate.inflate(body)
  when 'br'
    require 'brotli'
    body = Brotli.inflate(body)
  end

  # Detect bot protection page (Cloudflare, etc.)
  if body =~ /<title[^>]*>(?:Just a moment|Attention Required|DDOS Guardian|Access Denied)<\/title>/i
    raise "Bot protection page detected. Cannot retrieve content."
  end

  # Extract title
  title = body.match(/<title[^>]*>(.*?)<\/title>/i)&.[](1)&.strip
  if title
    title.gsub!(/&[a-z]+;/, ' ')
    title.gsub!(/\s+/, ' ')
  end

  # Extract first paragraph if enabled
  first_par = nil
  if @bot.config['url.first_par']
    if body =~ /<(?:p|div)[^>]*>(.*?)(?:<\/(?:p|div)>|$)/mi
      first_par = $1.strip.gsub(/<[^>]+>/, '').gsub(/\s+/, ' ')
      first_par = first_par[0...@bot.config['url.first_par_length']]
    end
  end

  {
    headers: response.each_header.to_h,
    title: title,
    content: first_par,
    body: body
  }
end

  def get_title_from_html(pagedata)
    return pagedata.ircify_html_title
  end

  def get_title_for_url(uri_str, opts = {})
    url = uri_str.kind_of?(URI) ? uri_str : URI.parse(uri_str)
    return if url.scheme !~ /https?/

    begin
      checks = Addrinfo.getaddrinfo(url.host, nil).map { |addr| addr.ip_address }
    rescue => e
      return "Unable to retrieve info for #{url.host}: #{e.message}"
    end
    checks << url.host
    checks.flatten!
    unless checks.grep(@no_info_hosts).empty?
      return ( opts[:always_reply] ? "Sorry, info retrieval for #{url.host} (#{checks.first}) is disabled" : false )
    end

    begin
      info = robust_fetch(url.to_s)
    rescue => e
      debug "robust_fetch failed: #{e.message}"
      # Fallback to the original filter
      begin
        info = @bot.filter(:htmlinfo, url)
      rescue => e
        raise "connecting to site/processing information (#{e.message})"
      end
    end

    title = info[:title]
    extra = []
    resp = info[:headers]

    if info[:content]
      max_length = @bot.config['url.first_par_length']
      whitelist = @bot.config['url.first_par_whitelist']
      content = nil
      if whitelist.length > 0
        whitelist.each do |pattern|
          if Regexp.new(pattern, Regexp::IGNORECASE).match(url.to_s)
            content = info[:content][0...max_length]
            break
          end
        end
      else
        content = info[:content][0...max_length] if @bot.config['url.first_par']
      end
      extra << "#{Bold}text#{Bold}: #{content}" if content
    else
      extra << "#{Bold}type#{Bold}: #{resp['content-type']}" unless title
      if enc = resp['content-encoding']
        extra << "#{Bold}encoding#{Bold}: #{enc}" if @bot.config['url.first_par'] or not title
      end
      if size = resp['content-length']
        size = size.gsub(/(\d)(?=\d{3}+(?:\.|$))(\d{3}\..*)?/,'\1,\2') rescue nil
        extra << "#{Bold}size#{Bold}: #{size} bytes" if size && (@bot.config['url.first_par'] or not title)
      end
    end

    call_event(:url_added, url.to_s, { title: title, extra: extra.join(", ") })
    if title
      extra.unshift("#{Bold}title#{Bold}: #{title}")
    end
    return extra.join(", ") if title or not @bot.config['url.titles_only']
  end

  def handle_urls(m, params={})
    opts = {
      :display_info => @bot.config['url.display_link_info'],
      :channels => @bot.config['url.only_on_channels'],
      :ignore => @bot.config['url.ignore']
    }.merge params
    urls = opts[:urls]
    display_info= opts[:display_info]
    channels = opts[:channels]
    ignore = opts[:ignore]

    unless channels.empty?
      return unless channels.map { |c| c.downcase }.include?(m.channel.downcase)
    end

    ignore.each { |u| return if m.source.matches?(u) }

    return if urls.empty?
    debug "found urls #{urls.inspect}"
    list = m.public? ? @registry[m.target] : nil
    debug "display link info: #{display_info}"
    urls_displayed = 0
    urls.each do |urlstr|
      debug "working on #{urlstr}"
      next unless urlstr =~ /^https?:\/\/./
      if @bot.config['url.auto_shorten'] == true and
         urlstr.length >= @bot.config['url.auto_shorten_min_length']
        m.reply(bot.plugins['shortenurls'].shorten(nil, {:url=>urlstr, :called=>true}))
        next
      end
      title = nil
      debug "Getting title for #{urlstr}..."
      reply = nil
      begin
        title = get_title_for_url(urlstr,
                                  :always_reply => m.address?,
                                  :nick => m.source.nick,
                                  :channel => m.channel,
                                  :ircline => m.message)
        debug "Title #{title ? '' : 'not '} found"
        reply = "#{LINK_INFO} #{title}" if title
      rescue => e
        debug e
        # we might get a 404 because of trailing punctuation, so we try again
        # with the last character stripped. this might generate invalid URIs
        # (e.g. because "some.url" gets chopped to some.url%2, so catch that too
        if e.message =~ /\(404 - Not Found\)/i or e.kind_of?(URI::InvalidURIError)
          # chop off last non-word character from the unescaped version of
          # the URL, and retry if we still have enough string to look like a
          # minimal URL
          unescaped = URI.unescape(urlstr)
          debug "Unescaped: #{unescaped}"
          if unescaped.sub!(/\W$/,'') and unescaped =~ /^https?:\/\/./
            urlstr.replace URI.escape(unescaped, OUR_UNSAFE)
            retry
          else
            debug "Not retrying #{unescaped}"
          end
        end
        reply = "Error #{e.message}"
      end

      if display_info > urls_displayed
        if reply
          m.reply reply, :overlong => :truncate, :to => :public,
            :nick => (m.address? ? :auto : false)
          urls_displayed += 1
        end
      end

      next unless list

      # check to see if this url is already listed
      next if list.find {|u| u.url == urlstr }

      url = Url.new(m.target, m.sourcenick, Time.new, urlstr, title)
      debug "#{list.length} urls so far"
      list.pop if list.length > @bot.config['url.max_urls']
      debug "storing url #{url.url}"
      list.unshift url
      debug "#{list.length} urls now"
    end
    @registry[m.target] = list
  end

  def info(m, params)
    escaped = URI.escape(params[:urls].to_s, OUR_UNSAFE)
    urls = URI.extract(escaped)
    Thread.new do
      handle_urls(m,
                  :urls => urls,
                  :display_info => params[:urls].length,
                  :channels => [])
    end
  end

  def message(m)
    return if m.address?

    urls = URI.extract(m.message, ['http', 'https'])
    return if urls.empty?
    Thread.new { handle_urls(m, :urls => urls) }
  end

  def reply_urls(opts={})
    list = opts[:list]
    max = opts[:max]
    channel = opts[:channel]
    m = opts[:msg]
    return unless list and max and m
    list[0..(max-1)].each do |url|
      disp = "[#{url.time.strftime('%Y/%m/%d %H:%M:%S')}] <#{url.nick}> #{url.url}"
      if @bot.config['url.info_on_list']
        title = url.info ||
          get_title_for_url(url.url,
                            :nick => url.nick, :channel => channel) rescue nil
        # If the url info was missing and we now have some, try to upgrade it
        if channel and title and not url.info
          ll = @registry[channel]
          debug ll
          if el = ll.find { |u| u.url == url.url }
            el.info = title
            @registry[channel] = ll
          end
        end
        disp << " --> #{title}" if title
      end
      m.reply disp, :overlong => :truncate
    end
  end

  def urls(m, params)
    channel = params[:channel] ? params[:channel] : m.target
    max = params[:limit].to_i
    max = 10 if max > 10
    max = 1 if max < 1
    list = @registry[channel]
    if list.empty?
      m.reply "no urls seen yet for channel #{channel}"
    else
      reply_urls :msg => m, :channel => channel, :list => list, :max => max
    end
  end

  def search(m, params)
    channel = params[:channel] ? params[:channel] : m.target
    max = params[:limit].to_i
    string = params[:string]
    max = 10 if max > 10
    max = 1 if max < 1
    regex = Regexp.new(string, Regexp::IGNORECASE)
    list = @registry[channel].find_all {|url|
      regex.match(url.url) || regex.match(url.nick) ||
        (@bot.config['url.info_on_list'] && regex.match(url.info))
    }
    if list.empty?
      m.reply "no matches for channel #{channel}"
    else
      reply_urls :msg => m, :channel => channel, :list => list, :max => max
    end
  end
end

plugin = UrlPlugin.new
plugin.map 'urls info *urls', :action => 'info'
plugin.map 'url info *urls', :action => 'info'
plugin.map 'urls search :channel :limit :string', :action => 'search',
                          :defaults => {:limit => 4},
                          :requirements => {:limit => /^\d+$/},
                          :public => false
plugin.map 'urls search :limit :string', :action => 'search',
                          :defaults => {:limit => 4},
                          :requirements => {:limit => /^\d+$/},
                          :private => false
plugin.map 'urls :channel :limit', :defaults => {:limit => 4},
                          :requirements => {:limit => /^\d+$/},
                          :public => false
plugin.map 'urls :limit', :defaults => {:limit => 4},
                          :requirements => {:limit => /^\d+$/},
                          :private => false