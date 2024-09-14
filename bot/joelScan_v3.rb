require "bundler/inline"
require "json"
require 'eventmachine'
require 'absolute_time'
require "awesome_print"
require 'faye/websocket'

gemfile do
  source "https://rubygems.org"
  gem "faraday"
  gem "mysql2"
end

require 'faraday'
require 'mysql2'
require_relative "credentials.rb"

$twitch_token = nil
$joinedChannels = []
$twitch_refresh_token = nil
$acceptedJoels = ["GoldenJoel" , "Joel2" , "Joeler" , "Joel" , "jol" , "JoelCheck" , "JoelbutmywindowsXPiscrashing" , "JOELLINES", "Joeling", "Joeling", "LetHimJoel", "JoelPride", "WhoLetHimJoel", "Joelest", "EvilJoel", "JUSSY", "JoelJams", "JoelTrain", "BarrelJoel", "JoelWide1", "JoelWide2", "Joeling2"]
$followedChannels = ["jakecreatesstuff", "venorrak", "lcolonq", "prodzpod", "cr4zyk1tty", "tyumici"]
$commandChannels = ["venorrak", "prodzpod", "cr4zyk1tty", "jakecreatesstuff", "tyumici", "lcolonq"]
$last_twitch_refresh = AbsoluteTime.now
$me_twitch_id = nil
$twitch_session_id = nil

$sql = Mysql2::Client.new(:host => "localhost", :username => "bot", :password => "joel", :reconnect => true, :database => "joelScan")

$twitch_auth_server = Faraday.new(url: 'https://id.twitch.tv') do |conn|
  conn.request :url_encoded
end

$twitch_api = Faraday.new(url: 'https://api.twitch.tv') do |conn|
  conn.request :url_encoded
end

$ntfy_server = Faraday.new(url: 'https://ntfy.venorrak.dev') do |conn|
  conn.request :url_encoded
end



#function to get the access token for API 
def getAccess()
  oauthToken = nil
  #https://dev.twitch.tv/docs/authentication/getting-tokens-oauth/#device-code-grant-flow
  response = $twitch_auth_server.post("/oauth2/device") do |req|
      req.headers["Content-Type"] = "application/x-www-form-urlencoded"
      req.body = "client_id=#{@client_id}&scopes=user:write:chat+user:read:chat"
  end
  rep = JSON.parse(response.body)
  device_code = rep["device_code"]

  # wait for user to authorize the app
  puts "Please go to #{rep["verification_uri"]} and enter the code #{rep["user_code"]}"
  puts "Press enter when you have authorized the app"
  wait = gets.chomp

  #https://dev.twitch.tv/docs/authentication/getting-tokens-oauth/#authorization-code-grant-flow
  response = $twitch_auth_server.post("/oauth2/token") do |req|
      req.body = "client_id=#{@client_id}&scopes=user:write:chat,user:read:chat,channel:manage:broadcast,user:manage:whispers&device_code=#{device_code}&grant_type=urn:ietf:params:oauth:grant-type:device_code"
  end
  rep = JSON.parse(response.body)
  $twitch_token = rep["access_token"]
  $twitch_refresh_token = rep["refresh_token"]
end

def refreshTwitchAccess()
  #https://dev.twitch.tv/docs/authentication/refresh-tokens/#how-to-use-a-refresh-token
  response = $twitch_auth_server.post("/oauth2/token") do |req|
      req.headers["Content-Type"] = "application/x-www-form-urlencoded"
      req.body = "grant_type=refresh_token&refresh_token=#{$twitch_refresh_token}&client_id=#{@client_id}&client_secret=#{@clientSecret}"
  end
  begin
    rep = JSON.parse(response.body)
  rescue
    p response.body
    return
  end
  if !rep["access_token"].nil? && !rep["refresh_token"].nil?
    $twitch_token = rep["access_token"]
    $twitch_refresh_token = rep["refresh_token"]
  else
    p "error refreshing twitch token"
    p rep
  end
end

def subscribeToTwitchEventSub(session_id, type, streamer_twitch_id)
  data = {
      "type" => type[:type],
      "version" => type[:version],
      "condition" => {
          "broadcaster_user_id" => streamer_twitch_id,
          "to_broadcaster_user_id" => $me_twitch_id,
          "user_id" => $me_twitch_id,
          "moderator_user_id" => $me_twitch_id
      },
      "transport" => {
          "method" => "websocket",
          "session_id" => session_id
      }
  }.to_json
  response = $twitch_api.post("/helix/eventsub/subscriptions", data) do |req|
      req.headers["Authorization"] = "Bearer #{$twitch_token}"
      req.headers["Client-Id"] = @client_id
      req.headers["Content-Type"] = "application/json"
  end
  return JSON.parse(response.body)
end

def unsubscribeToTwitchEventSub(subsciptionId)
  response = $twitch_api.delete("/helix/eventsub/subscriptions?id=#{subsciptionId}") do |req|
      req.headers["Authorization"] = "Bearer #{$twitch_token}"
      req.headers["Client-Id"] = @client_id
  end
  p response.status
end

def send_twitch_message(channel, message)
  if channel.is_a? Integer
    channel_id = channel
  else
    channel_id = getTwitchUser(channel)["data"][0]["id"]
  end
  begin
    message = "[📺] #{message}"
    request_body = {
        "broadcaster_id": channel_id,
        "sender_id": $me_twitch_id,
        "message": message
    }.to_json
    response_code = 429
    until response_code != 429
      response = $twitch_api.post("/helix/chat/messages", request_body) do |req|
          req.headers["Authorization"] = "Bearer #{$twitch_token}"
          req.headers["Client-Id"] = @client_id
          req.headers["Content-Type"] = "application/json"
      end
      response_code = response.status
    end
  rescue
    p "error sending message"
  end
end

#function to get the live channels from the channels array
def getLiveChannels()
  liveChannels = []
  channelsString = ""
  #https://dev.twitch.tv/docs/api/reference/#get-streams
  $followedChannels.each do |channel|
      response = $twitch_api.get("/helix/streams?user_login=#{channel}") do |req|
          req.headers["Authorization"] = "Bearer #{$twitch_token}"
          req.headers["Client-Id"] = @client_id
      end
      begin
          rep = JSON.parse(response.body)
          rep["data"].each do |stream|
              if stream["type"] == "live"
                  liveChannels << "#{stream["user_login"]}"
              end
          end
      rescue
          #if the response is not json or doesn't contain the data key
          liveChannels = []
      end
  end
  p liveChannels
  return liveChannels
end

def updateTrackedChannels()
  begin
    liveChannels = getLiveChannels()
  rescue
    sendNotif("Bot stopped checking channels", "Alert")
  end
  $followedChannels.each do |channel|
    #if the channel is live and the bot is not in the channel
    joinedChannelsName = $joinedChannels.map { |channel| channel[:channel] }
    if liveChannels.include?(channel) && !joinedChannelsName.include?(channel)
      subscribeData = subscribeToTwitchEventSub($twitch_session_id, {:type => "channel.chat.message", :version => "1"}, getTwitchUser(channel)["data"][0]["id"])
      $joinedChannels << {:channel => channel, :subscription_id => subscribeData["data"][0]["id"]}
      send_twitch_message(channel, "JoelBot has entered the chat")
      sendNotif("Bot joined #{channel}", "Alert Bot Joined Channel")
    end
    #if the channel is not live and the bot is in the channel
    if !liveChannels.include?(channel) && joinedChannelsName.include?(channel)
      leavingChannel = $joinedChannels.find { |channelData| channelData[:channel] == channel }
      unsubscribeToTwitchEventSub(leavingChannel[:subscription_id])
      $joinedChannels.delete(leavingChannel)
      send_twitch_message(channel, "JoelBot has left the chat")
      sendNotif("Bot left #{channel}", "Alert Bot Left Channel")
    end
  end
end

#function to get the user info from the API
def getTwitchUser(name)
  response = $twitch_api.get("/helix/users?login=#{name}") do |req|
      req.headers["Authorization"] = "Bearer #{$twitch_token}"
      req.headers["Client-Id"] = @client_id
  end
  begin
      rep = JSON.parse(response.body)
  rescue
      rep = {}
  end
  return rep
end

#function to send a notification to the ntfy server on JoelBot subject
def sendNotif(message, title)
  rep = $ntfy_server.post("/JoelBot") do |req|
      req.headers["host"] = "ntfy.venorrak.dev"
      req.headers["Priority"] = "5"
      req.headers["Title"] = title
      req.body = message
  end
end

#create a user and joel in the database
def createUserDB(name, userData, startJoels)
  pfp = nil
  bgp = nil
  twitch_id = nil
  user_id = 0
  pfp_id = 0
  bgp_id = 0

  userData["data"].each do |user|
      twitch_id = user["id"]
      pfp = user["profile_image_url"]
      bgp = user["offline_image_url"]
  end
  $sql.query("INSERT INTO pictures VALUES (DEFAULT, '#{pfp}', 'pfp');")
  $sql.query("INSERT INTO pictures VALUES (DEFAULT, '#{bgp}', 'bgp');")
  
  pfp_id = $sql.query("SELECT id FROM pictures WHERE url = '#{pfp}';").first["id"]
  bgp_id = $sql.query("SELECT id FROM pictures WHERE url = '#{bgp}';").first["id"]
  $sql.query("INSERT INTO users VALUES (DEFAULT, '#{twitch_id}', '#{pfp_id}', '#{bgp_id}', '#{name}', '#{DateTime.now.strftime("%Y-%m-%d")}');")
  #get the id of the new user
  $sql.query("SELECT id FROM users WHERE name = '#{name}';").each do |row|
      user_id = row["id"]
  end
  #add the user to the joels table and set the count to 1
  $sql.query("INSERT INTO joels VALUES (DEFAULT, #{user_id}, #{startJoels});")
end

#create a channel and channelJoels in the database
def createChannelDB(channelName)
  channel_id = 0
  #add the channel to the database
  $sql.query("INSERT INTO channels VALUES (DEFAULT, '#{channelName}', '#{DateTime.now.strftime("%Y-%m-%d")}');")
  #get the id of the new channel
  $sql.query("SELECT id FROM channels WHERE name = '#{channelName}';").each do |row|
      channel_id = row["id"]
  end
  #add the channel to the channelJoels table and set the count to 1
  $sql.query("INSERT INTO channelJoels VALUES (DEFAULT, #{channel_id}, 1);")

  #register the channel owner to the user database if it doesn't exist
  channelOwnerExists = false
  #sql request to search if user is in the database
  $sql.query("SELECT * FROM users WHERE name = '#{channelName}';").each do |row|
      channelOwnerExists = true
  end
  return channelOwnerExists
end

def joelReceived(receivedData, nbJoel)
  userName = receivedData["payload"]["event"]["chatter_user_login"]
  channelName = receivedData["payload"]["event"]["broadcaster_user_login"]
  #check if the user is in the database
  if $sql.query("SELECT * FROM users WHERE name = '#{userName}';").count > 0
    $sql.query("UPDATE joels SET count = count + #{nbJoel} WHERE user_id = (SELECT id FROM users WHERE name = '#{userName}');")
  else
    createUserDB(userName, getTwitchUser(userName), nbJoel)
  end
  #check if the channel is in the database
  if $sql.query("SELECT * FROM channels WHERE name = '#{channelName}';").count > 0
    $sql.query("UPDATE channelJoels SET count = count + #{nbJoel} WHERE channel_id = (SELECT id FROM channels WHERE name = '#{channelName}');")
  else
    createChannelDB(channelName)
  end
  #check if the channel owner is in the database
  if $sql.query("SELECT * FROM users WHERE name = '#{channelName}';").count == 0
    createUserDB(channelName, getTwitchUser(channelName), 0)
  end
  #check if the stream is in the database
  if $sql.query("SELECT * FROM streamJoels WHERE channel_id = (SELECT id FROM channels WHERE name = '#{channelName}') AND streamDate = '#{DateTime.now.strftime("%Y-%m-%d")}';").count > 0
    $sql.query("UPDATE streamJoels SET count = count + #{nbJoel} WHERE channel_id = (SELECT id FROM channels WHERE name = '#{channelName}') AND streamDate = '#{DateTime.now.strftime("%Y-%m-%d")}';")
  else
    $sql.query("INSERT INTO streamJoels VALUES (DEFAULT, (SELECT id FROM channels WHERE name = '#{channelName}'), #{nbJoel}, '#{DateTime.now.strftime("%Y-%m-%d")}');")
  end
end

def treatCommands(words, receivedData)
  chatterName = receivedData["payload"]["event"]["chatter_user_login"]
  channelId = receivedData["payload"]["event"]["broadcaster_user_id"]
  broadcastName = receivedData["payload"]["event"]["broadcaster_user_login"]
  if $commandChannels.include?(broadcastName)
    case words[0]
    when "!JoelCount"
      if words[1] != "" && words[1] != nil
        username = words[1]
        if $sql.query("SELECT * FROM users WHERE name = '#{username.downcase}';").count > 0
          count = $sql.query("SELECT count FROM joels WHERE user_id = (SELECT id FROM users WHERE name = '#{username.downcase}');").first["count"].to_i
          send_twitch_message(channelId.to_i, "#{username} has Joel'd #{count} times")
        else
          send_twitch_message(channelId.to_i, "#{username} didn't Joel yet")
        end
      else
        if $sql.query("SELECT * FROM users WHERE name = '#{chatterName.downcase}';").count > 0
          count = $sql.query("SELECT count FROM joels WHERE user_id = (SELECT id FROM users WHERE name = '#{chatterName.downcase}');").first["count"].to_i
          send_twitch_message(channelId.to_i, "#{chatterName} has Joel'd #{count} times")
        else
          send_twitch_message(channelId.to_i, "#{chatterName} didn't Joel yet")
        end
      end
    when "!JoelCountChannel"
      if words[1] != "" && words[1] != nil
        channelName = words[1]
        if $sql.query("SELECT * FROM channels WHERE name = '#{channelName.downcase}';").count > 0
          count = $sql.query("SELECT count FROM channelJoels WHERE channel_id = (SELECT id FROM channels WHERE name = '#{channelName.downcase}');").first["count"].to_i
          send_twitch_message(channelId.to_i, "Joel count on #{channelName} is #{count}")
        else
          send_twitch_message(channelId.to_i, "no Joel on #{channelName} channel yet")
        end
      else
        if $sql.query("SELECT * FROM channels WHERE name = '#{broadcastName.downcase}';").count > 0
          count = $sql.query("SELECT count FROM channelJoels WHERE channel_id = (SELECT id FROM channels WHERE name = '#{broadcastName.downcase}');").first["count"].to_i
          send_twitch_message(channelId.to_i, "Joel count on #{broadcastName} is #{count}")
        else
          send_twitch_message(channelId.to_i, "no Joel on this channel yet")
        end
      end
    when "!JoelCountStream"
      if $sql.query("SELECT * FROM streamJoels WHERE channel_id = (SELECT id FROM channels WHERE name = '#{broadcastName.downcase}') AND streamDate = '#{DateTime.now.strftime("%Y-%m-%d")}';").count > 0
        count = $sql.query("SELECT count FROM streamJoels WHERE channel_id = (SELECT id FROM channels WHERE name = '#{broadcastName.downcase}') AND streamDate = '#{DateTime.now.strftime("%Y-%m-%d")}';").first["count"].to_i
        send_twitch_message(channelId.to_i, "Joel count on this stream is #{count}")
      else
        send_twitch_message(channelId.to_i, "no Joel today yet")
      end
    when "!JoelTop"
      users = $sql.query("SELECT users.name, joels.count FROM users INNER JOIN joels ON users.id = joels.user_id ORDER BY joels.count DESC LIMIT 5;")
      message = ""
      users.each_with_index do |user, index|
        message += "#{user["name"]} : #{user["count"].to_i} | "
      end
      send_twitch_message(channelId.to_i, message)
    when "!JoelTopChannel"
      channels = $sql.query("SELECT channels.name, channelJoels.count FROM channels INNER JOIN channelJoels ON channels.id = channelJoels.channel_id ORDER BY channelJoels.count DESC LIMIT 5;")
      message = ""
      channels.each_with_index do |channel, index|
        message += "#{channel["name"]} : #{channel["count"].to_i} | "
      end
      send_twitch_message(channelId.to_i, message)
    when "!JoelCommands"
      send_twitch_message(channelId.to_i, "!JoelCount [username] - !JoelCountChannel [channelname] - !JoelCountStream - get the number of Joels on the current stream - !JoelTop - get the top 5 Joelers")
    end
  end
end

getAccess()
$me_twitch_id = getTwitchUser("venorrak")["data"][0]["id"]
if $me_twitch_id.nil?
  puts "error getting my twitch id"
  exit
end

Thread.start do
  loop do
    sleep(120)
    now = AbsoluteTime.now
    $sql.query("SELECT 1;")
    updateTrackedChannels()
    if now - $last_twitch_refresh > 7200
      refreshTwitchAccess()
      $last_twitch_refresh = now
    end
  end
end

def startWebsocket(url, isReconnect = false)
  EM.run do
    ws = Faye::WebSocket::Client.new(url)

    ws.on :open do |event|
      #p [:open]
    end

    ws.on :message do |event|
      begin
        receivedData = JSON.parse(event.data)
      rescue
        puts "non json data"
        return
      end
      if receivedData["metadata"]["message_type"] == "session_welcome"
        $twitch_session_id = receivedData["payload"]["session"]["id"]
        getLiveChannels().each do |channel|
          begin
            subscribeData = subscribeToTwitchEventSub($twitch_session_id, {:type => "channel.chat.message", :version => "1"}, getTwitchUser(channel)["data"][0]["id"])
            $joinedChannels << {:channel => channel, :subscription_id => subscribeData["data"][0]["id"]}
          rescue => exception
            puts exception
            p subscribeData
            startWebsocket("wss://eventsub.wss.twitch.tv/ws?keepalive_timeout_seconds=30", false)
            raise exception
          end
          if isReconnect == false
            send_twitch_message(channel, "JoelBot has entered the chat")
            sendNotif("JoelBot Joined #{channel}", "JoelBot")
          end
        end
        ap $joinedChannelsSubciptions
        #subscribeData = subscribeToTwitchEventSub($twitch_session_id, {:type => "channel.chat.message", :version => "1"}, getTwitchUser("venorrak")["data"][0]["id"])
      end
      if receivedData["metadata"]["message_type"] == "session_reconnect"
        startWebsocket(receivedData["payload"]["session"]["reconnect_url"], true)
      end
      if receivedData["metadata"]["message_type"] == "notification"
        case receivedData["payload"]["subscription"]["type"]
        when "channel.chat.message"
          message = receivedData["payload"]["event"]["message"]["text"]
          puts "#{receivedData["payload"]["event"]["chatter_user_login"]}: #{message}"
          words = message.split(" ")
          treatCommands(words, receivedData)
          nbJoelInMessage = 0
          words.each do |word|
            if $acceptedJoels.include?(word)
              nbJoelInMessage += 1
            end
          end
          if nbJoelInMessage > 0
            #if the message is not sent by the bot
            if receivedData["payload"]["event"]["chatter_user_login"] == "venorrak" && words[0] == "[📺]"
              print("")
            else
              joelReceived(receivedData, nbJoelInMessage)
            end
          end
        end
      end
    end

    ws.on :close do |event|
      p [:close, event.code, event.reason, "twitch"]
      ap $joinedChannelsSubciptions
      if event.code != 1000 && event.code != 1006 && event.code != 4004
        sendNotif("JoelBot Disconnected : #{event.code} : #{event.reason}", "JoelBot")
      end
      if event.code != 1000
        startWebsocket("wss://eventsub.wss.twitch.tv/ws?keepalive_timeout_seconds=30", true)
      end
    end
  end
end

startWebsocket("wss://eventsub.wss.twitch.tv/ws?keepalive_timeout_seconds=30")