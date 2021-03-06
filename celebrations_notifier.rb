require 'date'
require 'google/apis/admin_directory_v1'
require 'googleauth'
require 'googleauth/stores/file_token_store'
require 'fileutils'
require 'icalendar'
require 'net/http'
require 'slack-ruby-client'

include Icalendar # Probably do this in your class to limit namespace overlap

##### google API const below
OOB_URI = 'urn:ietf:wg:oauth:2.0:oob'.freeze
APPLICATION_NAME = 'Directory API Ruby Quickstart'.freeze
CLIENT_SECRETS_PATH = 'client_secret.json'.freeze
CREDENTIALS_PATH = File.join(Dir.home, '.credentials',
                             'admin-directory_v1-ruby-quickstart.yaml')
SCOPE = Google::Apis::AdminDirectoryV1::AUTH_ADMIN_DIRECTORY_USER_READONLY
#### google API const above

def get_links
  # Anniversary Feed Link (iCal) from Bamboo
  @anniversary_link = ENV['ANNIVERSARY_LINK']

  # Birthday Feed Link (iCal) from Bamboo
  @birthday_link    = ENV['BIRTHDAY_LINK']

  # File Names
  @anniversary_file = 'anniversaries.ics'
  @birthday_file    = 'birthdays.ics'

  # Variables Declaration
  @anniversaries = []
  @birthdays = []
  @emails = {}
  @slack_data = {}

  Slack.configure do |config|
    config.token = ENV['SLACK_TOKEN']
    puts 'Invalid Token!' unless config.token
    raise 'Invalid Token!' unless config.token
  end

  @client = Slack::Web::Client.new

  @client.auth_test
end

def download_files
  File.write(@anniversary_file, Net::HTTP.get(URI.parse(@anniversary_link)))
  File.write(@birthday_file, Net::HTTP.get(URI.parse(@birthday_link)))
end

def construct_array(location, hash_name)
  cal_file = File.open(location)
  cal = Icalendar::Calendar.parse(cal_file).first

  cal.events.each do |e|
    next unless e.dtstart == Date.today + 2 # + 6 # Test
    event = {}
    event['name'] = (location == @anniversary_file ? e.summary[0..e.summary.index('(') - 1].strip : e.summary[0..e.summary.index('-') - 1].strip)
    event['duration'] = e.summary[e.summary.index('(') + 1...e.summary.length - 1].strip.gsub!('yr', 'year') if location == @anniversary_file
    hash_name.append(event)
  end
  pp hash_name
end

def fill_emails(array)
  user_dict = @emails
  array.each do |user|
    user.merge!('email' => user_dict[user['name']]) if user_dict[user['name']]
  end
end

def authorize
  FileUtils.mkdir_p(File.dirname(CREDENTIALS_PATH))

  client_id = Google::Auth::ClientId.from_file(CLIENT_SECRETS_PATH)
  token_store = Google::Auth::Stores::FileTokenStore.new(file: CREDENTIALS_PATH)
  authorizer = Google::Auth::UserAuthorizer.new(
    client_id, SCOPE, token_store
  )
  user_id = 'default'
  credentials = authorizer.get_credentials(user_id)
  if credentials.nil?
    url = authorizer.get_authorization_url(
      base_url: OOB_URI
    )
    puts 'Open the following URL in the browser and enter the resulting code after authorization'
    puts url
    code = gets
    credentials = authorizer.get_and_store_credentials_from_code(
      user_id: user_id, code: code, base_url: OOB_URI
    )
  end
  credentials.fetch_access_token!({}) if credentials.expired?
  credentials
end

def get_response_array
  service = Google::Apis::AdminDirectoryV1::DirectoryService.new
  service.client_options.application_name = APPLICATION_NAME
  service.authorization = authorize
  res = []
  response = service.list_users(domain: 'appfolio.com',
                                order_by: 'email',
                                max_results: 500,
                                view_type: 'domain_public')
  res += response.users
  response = service.list_users(domain: 'appfolio.com',
                                order_by: 'email',
                                max_results: 500,
                                view_type: 'domain_public',
                                page_token: response.next_page_token)
  res += response.users
  response = service.list_users(domain: 'mycase.com',
                                order_by: 'email',
                                max_results: 500,
                                view_type: 'domain_public')
  res += response.users
  res
end

def get_emails
  array = get_response_array
  array.each do |user|
    @emails[user.name.full_name] = user.primary_email
  end
end

def fill_slack_data
  response = @client.users_list(channel: '#general')
  members_data = response['members']

  members_data.each do |d|
    @slack_data[d['profile']['email']] = d['name'] unless (d['profile']['email'].blank? || d['name'].blank? || d['is_bot'] || d['disabled'])
  end

end

def send_notification
  names = []
  @anniversaries.each do |emp|
    if @slack_data[emp['email']].blank?
      names.append("Happy anniversary #{emp['name']}!")
    else
      names.append("Happy anniversary #{emp['name']} (@#{@slack_data[emp['email']]})!") unless @slack_data[emp['email']].blank?
    end
  end

  @birthdays.each do |emp|
    if @slack_data[emp['email']].blank?
      names.append("Happy birthday #{emp['name']}!")
    else
      names.append("Happy birthday #{emp['name']} (@#{@slack_data[emp['email']]})!") unless @slack_data[emp['email']].blank?
    end
  end

  names.each do |m|
    @client.chat_postMessage(channel: '#celebrationsnotifier', text: m.to_s, as_user: false, username: 'Celebrations Notifier')
  end
    @client.chat_postMessage(channel: '#celebrationsnotifier', link_names: 1, text: '@mohanc Hello', as_user: false, username: 'Celebrations Notifier')
  p 'No Notifications today!' if names.empty?
end

pp Date.today - 1
get_links
download_files
construct_array(@anniversary_file, @anniversaries)
construct_array(@birthday_file, @birthdays)
get_emails
fill_emails(@anniversaries)
fill_emails(@birthdays)
fill_slack_data
send_notification
