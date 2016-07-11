#!/usr/bin/env ruby
# encoding: utf-8
require 'json'
require 'sinatra'
require 'oauth'
require 'omniauth-twitter'

configure do
  set :server, :puma
  set :sessions, true
  set :environment, :production

  use OmniAuth::Builder do
    provider :twitter, settings.twitter_consumer_key, settings.twitter_consumer_secret
  end
end

helpers do
  def h(text)
    Rack::Utils.escape_html(text)
  end

  def prepare_access_token(oauth_token, oauth_token_secret)
    consumer = OAuth::Consumer.new(settings.twitter_consumer_key, settings.twitter_consumer_secret, {:site => "https://api.twitter.com", :scheme => :header })
    token_hash = { :oauth_token => oauth_token, :oauth_token_secret => oauth_token_secret }
    access_token = OAuth::AccessToken.from_hash(consumer, token_hash)

    return access_token
  end
end

get "/auth/twitter/callback" do
  session[:token] = request.env["omniauth.auth"]["credentials"]["token"]
  session[:secret] = request.env["omniauth.auth"]["credentials"]["secret"]

  redirect "/add"
end

get "/auth/failure" do
  @error = "Could not authenticate you with Twitter."
  erb :index
end

get "/" do
  @error = nil
  erb :index
end

get "/add" do
  case params[:error_code]
  when "1"
    @error = "<h3>Could not authenticate you with Twitter</h3>"
  when "2"
    @error = "<h3>Could not find that Twitter user</h3> <p>Please make sure you’ve typed their username correctly. Twitter usernames can only contain letters, numbers, and underscores.</p>"
  when "3"
    @error = "<h3>Could not retrieve followed accounts</h3> <p>Does this user have a private account?</p>"
  when "4"
    @error = "<h3>Could not create list</h3> <p>Twitter imposes a limit on how often third party services can access your account. Please wait 15 minutes then try again.</p>"
  when "5"
    @error = "<h3>Could not modify list</h3> <p>Twitter imposes a limit on how often third party services can access your account. Please wait 15 minutes then try again.</p>"
  else
    @error = nil
  end

  @access_token = session[:token]
  @secret = session[:secret]
  
  erb :add
end 

post "/create_list" do 
  begin
    screen_name = params[:screen_name]
    twitter_access_token = params[:access_token]
    twitter_access_token_secret = params[:secret]

    raise "1" if twitter_access_token.nil? or twitter_access_token_secret.nil?
    raise "2" if !!(screen_name =~ /[^\w]/)

    # Generate OAuth access token
    access_token = prepare_access_token(twitter_access_token, twitter_access_token_secret)
    
    # Get following list for `screen_name`
    request = access_token.request(:get, "https://api.twitter.com/1.1/friends/ids.json?cursor=-1&screen_name=#{screen_name}&count=5000")
    raise "3" if request.code != "200"

    response = JSON.parse(request.body, {:symbolize_names => true})
    ids = response[:ids]
    total = ids.length

    # Get our lists
    request = access_token.request(:get, "https://api.twitter.com/1.1/lists/list.json")
    response = JSON.parse(request.body, {:symbolize_names => true})

    # Check if we already have a list
    list = response.find{ |list| list[:slug] == screen_name }
    # Otherwise make one
    if list.nil?
      request = access_token.request(:post, "https://api.twitter.com/1.1/lists/create.json?name=#{screen_name}&mode=private&description=List%20generated%20by%20Otherside%20for%20Twitter%20https%3A%2F%2Fotherside.site")
      list = JSON.parse(request.body, {:symbolize_names => true})
    end
    
    list_id = list[:id_str]
    slug = list[:slug]
    owner_screen_name = list[:user][:screen_name]
    uri = list[:uri]

    raise "4" if list_id.nil?

    # Add our target to the list so we can see their replies
    request = access_token.request(:post, "https://api.twitter.com/1.1/lists/members/create.json?list_id=#{list_id}&screen_name=#{screen_name}")

    raise "5" if request.code != "200"

    # Iterate over the list of accounts
    complete = 0
    ids.each_slice(100) do |slice|
      complete += slice.length
      user_list = slice.join(",")

      access_token.request(:post, "https://api.twitter.com/1.1/lists/members/create_all.json?list_id=#{list_id}&user_id=#{user_list}")
    end

    redirect "https://twitter.com#{uri}"
  rescue Exception => @error
    redirect "/add?error_code=#{@error}"
  end
end