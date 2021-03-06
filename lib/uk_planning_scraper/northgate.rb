require 'http'
require 'nokogiri'
require 'logger'

module UKPlanningScraper
  def self.scrape_northgate(search_url, params, options)
    puts "Using Northgate scraper."
    base_url = search_url.match(/(https?:\/\/.+?)\//)[1]
    
    # Remove 'generalsearch.aspx' from the end and add '/Generic/' - case sensitive?
    generic_url = search_url.match(/.+\//)[0] + 'Generic/'
    
    apps = []

    $stdout.sync = true # Flush output buffer after every write so log messages appear immediately.
    logger = Logger.new($stdout)
    logger.level = Logger::DEBUG

    date_regex = /\d{2}-\d{2}-\d{4}/

    form_vars = {
      'csbtnSearch' => 'Search' # required
    }

    form_vars['txtProposal'] = params[:keywords]

    # Date received from and to
    if params[:received_from] || params[:received_to]
      form_vars['cboSelectDateValue'] = 'DATE_RECEIVED'
      form_vars['rbGroup'] = 'rbRange'
      form_vars['dateStart'] = params[:received_from].to_s if params[:received_from] # YYYY-MM-DD
      form_vars['dateEnd'] = params[:received_to].to_s if params[:received_to] # YYYY-MM-DD
    end

    # Date validated from and to
    if params[:validated_from] || params[:validated_to]
      form_vars['cboSelectDateValue'] = 'DATE_VALID'
      form_vars['rbGroup'] = 'rbRange'
      form_vars['dateStart'] = params[:validated_from].to_s if params[:validated_from] # YYYY-MM-DD
      form_vars['dateEnd'] = params[:validated_to].to_s if params[:validated_to] # YYYY-MM-DD
    end

    # Date decided from and to
    if params[:decided_from] || params[:decided_to]
      form_vars['cboSelectDateValue'] = 'DATE_DECISION'
      form_vars['rbGroup'] = 'rbRange'
      form_vars['dateStart'] = params[:decided_from].to_s if params[:decided_from] # YYYY-MM-DD
      form_vars['dateEnd'] = params[:decided_to].to_s if params[:decided_to] # YYYY-MM-DD
    end


    # form_vars.merge!({ 'cboStatusCode' => ENV['MORPH_STATUS']}) if ENV['MORPH_STATUS']

    logger.info "Form variables: #{form_vars.to_s}"

    headers = {
      'Origin' => base_url,
      'Referer' => search_url,
    }

    logger.debug "HTTP request headers:"
    logger.debug(headers.to_s)

    logger.debug "GET: " + search_url
    response = HTTP.headers(headers).get(search_url)
    logger.debug "Response code: HTTP " + response.code.to_s

    if response.code == 200
      doc = Nokogiri::HTML(response.to_s)
      asp_vars = {
        '__VIEWSTATE' => doc.at('#__VIEWSTATE')['value'],
        '__EVENTVALIDATION' => doc.at('#__EVENTVALIDATION')['value']
       }
    else
      logger.fatal "Bad response from search page. Response code: #{response.code.to_s}. Exiting."
      exit 1
    end

    cookies = {}
    response.cookies.each { |c| cookies[c.name] = c.value }

    form_vars.merge!(asp_vars)

    logger.debug "POST: " + search_url
    response2 = HTTP.headers(headers).cookies(cookies).post(search_url, :form => form_vars)
    logger.debug "Response code: HTTP " + response2.code.to_s

    if response2.code == 302
      # Follow the redirect manually
      # Set the page size (PS) to max so we don't have to page through search results
      logger.debug "Location: #{response2.headers['Location']}"
      # exit
      results_url = URI::encode(base_url + response2.headers['Location'].gsub!('PS=10', 'PS=99999'))
      
      logger.debug "GET: " + results_url
      response3 = HTTP.headers(headers).cookies(cookies).get(results_url)
      logger.debug "Response code: HTTP " + response3.code.to_s
      doc = Nokogiri::HTML(response3.to_s)
    else
      logger.fatal "Didn't get redirected from search. Exiting."
      exit 1
    end

    rows = doc.search("table.display_table tr")
    logger.info "Found #{rows.size - 1} applications in search results." # The first row is the header row

    # Iterate over search results
    rows.each do |row|
      if row.at("td") # skip header row which only has th's
        cells = row.search("td")
        ref = cells[0].inner_text.strip

        app = {
          scraped_at: Time.now,
          # date_scraped: Date.today # FIXME - Planning Alerts compatibility?
        }

        app[:council_reference] = ref
        app[:info_url] = URI::encode(generic_url + cells[0].at('a')[:href].strip)
        app[:info_url].gsub!(/%0./, '') # FIXME. Strip junk chars from URL - how can we prevent this?
        app[:address] = cells[1].inner_text.strip
        app[:description] = cells[2].inner_text.strip
        app[:status] = cells[3].inner_text.strip
        
        raw_date_received = cells[4].inner_text.strip
        
        if raw_date_received != '--'
          app[:date_received] = Date.parse(raw_date_received)
        else
          app[:date_received] = nil
        end
        
        app[:decision] = cells[5].inner_text.strip if cells[5] # Some councils don't have this column, eg Hackney
        apps << app
      end
    end
    apps
  end
end
