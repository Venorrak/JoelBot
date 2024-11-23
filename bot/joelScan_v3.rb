require "bundler/inline"
require "json"
require 'eventmachine'
require 'absolute_time'
require "awesome_print"
require 'faye/websocket'
require 'irb'

gemfile do
  source "https://rubygems.org"
  gem "faraday"
  gem "mysql2"
end

require 'faraday'
require 'mysql2'
require_relative "credentials.rb"

$online = false

$twitch_token = nil
$joinedChannels = []
$twitch_refresh_token = nil
$acceptedJoels = ["GoldenJoel" , "Joel2" , "Joeler" , "Joel" , "jol" , "JoelCheck" , "JoelbutmywindowsXPiscrashing" , "JOELLINES", "Joeling", "Joeling", "LetHimJoel", "JoelPride", "WhoLetHimJoel", "Joelest", "EvilJoel", "JUSSY", "JoelJams", "JoelTrain", "BarrelJoel", "JoelWide1", "JoelWide2", "Joeling2"]
$followedChannels = ["jakecreatesstuff", "venorrak", "lcolonq", "prodzpod", "cr4zyk1tty", "tyumici", "colinahscopy_"]
$lastJoelPerStream = []
$lastStreamJCP = []
$commandChannels = ["venorrak", "prodzpod", "cr4zyk1tty", "jakecreatesstuff", "tyumici", "lcolonq", "colinahscopy_"]
$last_twitch_refresh = AbsoluteTime.now
$twoMinWait = AbsoluteTime.now
$initiationDateTime = Time.new()
$me_twitch_id = nil
$twitch_session_id = nil
$JCP = 0

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
    sendNotif("Error refreshing twitch token", "Alert")
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
          if rep.nil? || rep["data"].nil?
            return response.body
          end
          rep["data"].each do |stream|
              if stream["type"] == "live"
                  liveChannels << "#{stream["user_login"]}"
              end
          end
      rescue => exception
        puts exception
        #if the response is not json or doesn't contain the data key
        return response.body
      end
  end
  return liveChannels
end

def getLastStreamJCP(channelName)
  # JCP = JoelCount / StreamDuration(in minutes)
  channelId = getTwitchUser(channelName)["data"][0]["id"] rescue nil
  if channelId.nil?
    return nil
  end
  response = $twitch_api.get("/helix/videos?user_id=#{channelId}&first=1&type=archive") do |req|
    req.headers["Authorization"] = "Bearer #{$twitch_token}"
    req.headers["Client-Id"] = @client_id
  end
  begin
    rep = JSON.parse(response.body)
  rescue
    return nil
  end
  if rep["data"].count == 0
    videoDuration = "0m0s"
  else
    videoInfo = rep["data"][0]
    videoDuration = videoInfo["duration"]
  end
  #duration ex: 3m21s
  videoDuration.delete_suffix!("s")
  minutes = videoDuration.split("m")[0].to_f
  seconds = videoDuration.split("m")[1].to_f
  totalMinutes = (minutes * 60 + seconds) / 60
  totalJoelCountLastStream = $sql.query("SELECT count FROM streamJoels WHERE channel_id = (SELECT id FROM channels WHERE name = '#{channelName}') ORDER BY streamDate DESC LIMIT 1;").first["count"].to_i rescue 0
  return totalJoelCountLastStream / totalMinutes rescue 0
end

def updateLastStreamJCP()
  lastStreamJCP = []
  $followedChannels.each do |channel|
    lastStreamJCP = getLastStreamJCP(channel)
    if lastStreamJCP.nil?
      next
    end
    $lastStreamJCP << {channel: channel, JCP: lastStreamJCP}
  end
end

def updateJCP()
  now = Time.new()
  uptime = (now - $initiationDateTime) / 60
  joinedChannelsName = $joinedChannels.map { |channel| channel[:channel] }
  allTimesSinceLastJoel = []
  $followedChannels.each do |channel|
    if joinedChannelsName.include?(channel)
      timeSinceLastJoel = (now - $lastJoelPerStream.find { |channelData| channelData[:channel] == channel }[:lastJoel]) / 60#minutes
    else
      joelPerMinute = $lastStreamJCP.find { |channelData| channelData[:channel] == channel }[:JCP] # Joels per minute
      minutePerJoel = 1.0 / joelPerMinute rescue 0 # Minutes per Joel
      # what is the time since last Joel if Joel is said every JoelPerMinute minutes since uptime
      if minutePerJoel != 0 && minutePerJoel != Float::INFINITY
        timeSinceLastJoel = uptime % minutePerJoel
      else
        timeSinceLastJoel = 0
      end
    end
    if timeSinceLastJoel != 0
      allTimesSinceLastJoel << timeSinceLastJoel
    end
  end

  # if all the the timeSinceLastJoel are equal -> JCP = 100%
  # if all the the timeSinceLastJoel are different -> JCP = 0%
  # if the timeSinceLastJoel are different -> JCP = 100 * (1 - (max - min) / max)
  if allTimesSinceLastJoel.uniq.count == 1
    $JCP = 100
  else
    $JCP = 100 * (1 - (allTimesSinceLastJoel.max - allTimesSinceLastJoel.min) / allTimesSinceLastJoel.max)
  end
end

def createEmptyDataForLastJoel()
  $followedChannels.each do |channel|
    $lastJoelPerStream << {channel: channel, lastJoel: Time.new()}
  end
end

def updateTrackedChannels()
  begin
    liveChannels = getLiveChannels()
  rescue
    sendNotif("Bot stopped checking channels", "Alert")
  end
  if liveChannels.count > 0 && $online == false
    $online = true
    startWebsocket("wss://eventsub.wss.twitch.tv/ws?keepalive_timeout_seconds=30")
  else
    joinedChannelsName = $joinedChannels.map { |channel| channel[:channel] }
    #if there is multiple subscriptions to the same channel, keep only the last one based on the subscription time
    $joinedChannels = $joinedChannels.group_by { |channel| channel[:channel] }.map { |k, v| v.max_by { |channel| channel[:subscription_time] } }    

    $followedChannels.each do |channel|
      #if the channel is live and the bot is not in the channel
      if liveChannels.include?(channel) && !joinedChannelsName.include?(channel)
        begin
          subscribeData = subscribeToTwitchEventSub($twitch_session_id, {:type => "channel.chat.message", :version => "1"}, getTwitchUser(channel)["data"][0]["id"])
          $joinedChannels << {:channel => channel, :subscription_id => subscribeData["data"][0]["id"], :subscription_time => AbsoluteTime.now}
          send_twitch_message(channel, "JoelBot has entered the chat")
          sendNotif("Bot joined #{channel}", "Alert Bot Joined Channel")
        rescue => exception
          puts exception
          p subscribeData
          p $joinedChannels
        end
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

  #update $lastJoelPerStream
  $lastJoelPerStream.each do |channel|
    if channel[:channel] == channelName
      channel[:lastJoel] = Time.new()
    end
  end

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

  #check if the User Joel stream is in the database
  if $sql.query("SELECT streamUsersJoels.user_id, streamUsersJoels.stream_id, channels.name, users.name FROM streamUsersJoels INNER JOIN streamJoels ON streamJoels.id = streamUsersJoels.stream_id INNER JOIN channels ON channels.id = streamJoels.channel_id INNER JOIN users ON users.id = streamUsersJoels.user_id WHERE channels.name = '#{channelName}' AND users.name = '#{userName}' AND streamJoels.streamDate = '#{DateTime.now.strftime("%Y-%m-%d")}';").count > 0
    $sql.query("UPDATE streamUsersJoels SET count = count + #{nbJoel} WHERE user_id = (SELECT id FROM users WHERE name = '#{userName}') AND stream_id = (SELECT id FROM streamJoels WHERE channel_id = (SELECT id FROM channels WHERE name = '#{channelName}') AND streamDate = '#{DateTime.now.strftime("%Y-%m-%d")}');")
  else
    $sql.query("INSERT INTO streamUsersJoels VALUES (DEFAULT, (SELECT id FROM streamJoels WHERE channel_id = (SELECT id FROM channels WHERE name = '#{channelName}') AND streamDate = '#{DateTime.now.strftime("%Y-%m-%d")}'), (SELECT id FROM users WHERE name = '#{userName}'), #{nbJoel});")
  end
end

def treatCommands(words, receivedData)
  chatterName = receivedData["payload"]["event"]["chatter_user_login"]
  channelId = receivedData["payload"]["event"]["broadcaster_user_id"]
  broadcastName = receivedData["payload"]["event"]["broadcaster_user_login"]
  if $commandChannels.include?(broadcastName)
    case words[0].downcase
    when "!joelcount"
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
    when "!joelcountchannel"
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
    when "!joelcountstream"
      if $sql.query("SELECT * FROM streamJoels WHERE channel_id = (SELECT id FROM channels WHERE name = '#{broadcastName.downcase}') AND streamDate = '#{DateTime.now.strftime("%Y-%m-%d")}';").count > 0
        count = $sql.query("SELECT count FROM streamJoels WHERE channel_id = (SELECT id FROM channels WHERE name = '#{broadcastName.downcase}') AND streamDate = '#{DateTime.now.strftime("%Y-%m-%d")}';").first["count"].to_i
        send_twitch_message(channelId.to_i, "Joel count on this stream is #{count}")
      else
        send_twitch_message(channelId.to_i, "no Joel today yet")
      end
    when "!joeltop"
      users = $sql.query("SELECT users.name, joels.count FROM users INNER JOIN joels ON users.id = joels.user_id ORDER BY joels.count DESC LIMIT 5;")
      message = ""
      users.each_with_index do |user, index|
        message += "#{user["name"]} : #{user["count"].to_i} | "
      end
      send_twitch_message(channelId.to_i, message)
    when "!joeltopchannel"
      channels = $sql.query("SELECT channels.name, channelJoels.count FROM channels INNER JOIN channelJoels ON channels.id = channelJoels.channel_id ORDER BY channelJoels.count DESC LIMIT 5;")
      message = ""
      channels.each_with_index do |channel, index|
        message += "#{channel["name"]} : #{channel["count"].to_i} | "
      end
      send_twitch_message(channelId.to_i, message)
    when "!joelcommands"
      send_twitch_message(channelId.to_i, "!JoelCount [username] - !JoelCountChannel [channelname] - !JoelCountStream - get the number of Joels on the current stream - !JoelTop - get the top 5 Joelers - !JoelTopChannel - get the top 5 channels with the most Joels")
    when "!joelstats"
      if words[1] != "" && words[1] != nil
        username = words[1]
      else
        username = chatterName
      end
      if $sql.query("SELECT * FROM users WHERE name = '#{username.downcase}';").count > 0
        basicStats = $sql.query("SELECT joels.count as totalJoels, users.creationDate as firstJoelDate FROM users JOIN joels ON users.id = joels.user_id WHERE users.name = '#{username.downcase}' LIMIT 1;").first
        mostJoelStreamStats = $sql.query("SELECT channels.name as MostJoelsInStreamStreamer, streamUsersJoels.count as mostJoelsInStream, streamJoels.streamDate as mostJoelsInStreamDate FROM users JOIN streamUsersJoels ON users.id = streamUsersJoels.user_id JOIN streamJoels ON streamUsersJoels.stream_id = streamJoels.id JOIN channels ON streamJoels.channel_id = channels.id WHERE users.name = '#{username.downcase}' AND streamUsersJoels.count = (SELECT MAX(streamUsersJoels.count) FROM streamUsersJoels WHERE user_id = users.id);").first
        mostJoeledStreamerStats = $sql.query("SELECT channels.name as mostJoeledStreamer, (SELECT SUM(streamUsersJoels.count) WHERE streamUsersJoels.user_id = users.id AND streamUsersJoels.stream_id = streamJoels.id ) as count FROM users JOIN streamUsersJoels ON users.id = streamUsersJoels.user_id JOIN streamJoels ON streamUsersJoels.stream_id = streamJoels.id JOIN channels ON streamJoels.channel_id = channels.id WHERE users.name = '#{username.downcase}' GROUP BY channels.id ORDER BY count DESC;").first

        message = "#{username} has Joel'd #{basicStats["totalJoels"].to_i} times since #{basicStats["firstJoelDate"]} / "
        message += "Most Joels in a stream : #{mostJoelStreamStats["mostJoelsInStream"]} on #{mostJoelStreamStats["mostJoelsInStreamDate"]} on #{mostJoelStreamStats["MostJoelsInStreamStreamer"]} / "
        message += "Most Joeled streamer : #{mostJoeledStreamerStats["count"]} on #{mostJoeledStreamerStats["mostJoeledStreamer"]}"
        send_twitch_message(channelId.to_i, message)
      else
        send_twitch_message(channelId.to_i, "#{username} didn't Joel yet")
      end
    when "!jcp"
      send_twitch_message(channelId.to_i, "JCP : #{$JCP.round(2)}%")
    when "!joelstatus"
      send_twitch_message(channelId.to_i, "JoelBot is online")
    end
  end
end

getAccess()
$me_twitch_id = getTwitchUser("venorrak")["data"][0]["id"]
if $me_twitch_id.nil?
  puts "error getting my twitch id"
  exit
end
updateLastStreamJCP()
createEmptyDataForLastJoel()

Thread.start do
  loop do
    begin
      sleep(1)
      now = AbsoluteTime.now
      updateJCP()
      if now - $twoMinWait > 120
        $sql.query("SELECT 1;")
        updateTrackedChannels()
        updateLastStreamJCP()
        $twoMinWait = now
      end
      if now - $last_twitch_refresh > 5000
        refreshTwitchAccess()
        $last_twitch_refresh = now
      end
    rescue => exception
      puts exception
      sendNotif("Bot stopped checking channels", "Alert")
      binding.irb
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
        liveChannels = getLiveChannels() rescue []
        joinedChannelsName = $joinedChannels.map { |channel| channel[:channel] }
        $followedChannels.each do |channel|
          #if the channel is live and the bot is not in the channel

          if joinedChannelsName.include?(channel)
            leavingChannel = $joinedChannels.find { |channelData| channelData[:channel] == channel }
            unsubscribeToTwitchEventSub(leavingChannel[:subscription_id])
            $joinedChannels.delete(leavingChannel)
          end

          if liveChannels.include?(channel) && !joinedChannelsName.include?(channel)
            begin
              subscribeData = subscribeToTwitchEventSub($twitch_session_id, {:type => "channel.chat.message", :version => "1"}, getTwitchUser(channel)["data"][0]["id"])
              $joinedChannels << {:channel => channel, :subscription_id => subscribeData["data"][0]["id"], :subscription_time => AbsoluteTime.now}
              if isReconnect == false
                send_twitch_message(channel, "JoelBot has entered the chat, !JoelCommands for commands")
                sendNotif("Bot joined #{channel}", "Alert Bot Joined Channel")
              end
            rescue => exception
              puts exception
              p subscribeData
              p $joinedChannels
            end
          end
        end
      end

      if receivedData["metadata"]["message_type"] == "session_reconnect"
        startWebsocket(receivedData["payload"]["session"]["reconnect_url"], true)
      end

      if receivedData["metadata"]["message_type"] == "notification"
        case receivedData["payload"]["subscription"]["type"]
        when "channel.chat.message"
          message = receivedData["payload"]["event"]["message"]["text"]
          puts "#{receivedData["payload"]["event"]["chatter_user_login"]}: #{message}"
          words = message.strip.split(" ")
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
      p [Time.now().to_s.split(" ")[1], :close, event.code, event.reason, "twitch"]
      if event.code != 1000
        #sendNotif("JoelBot Disconnected : #{event.code} : #{event.reason}", "JoelBot")
        if getLiveChannels().count > 0
          startWebsocket("wss://eventsub.wss.twitch.tv/ws?keepalive_timeout_seconds=30", true)
          $online = true
        else
          $online = false
        end
      end
    end
  end
end

if getLiveChannels().count > 0
  $online = true
  startWebsocket("wss://eventsub.wss.twitch.tv/ws?keepalive_timeout_seconds=30")
end

#keep the bot running until the user types exit
input = ""
until input == "exit"
  input = gets.chomp
  if input == "irb"
    binding.irb
  end
end



# - gcp
#   -has servers sending random numbers
#   -calculates how far apart the numbers are
#   -if they are far apart = high network variance
#   -if they are close = low network variance
#
# - Joelbot (Jcp)
#   -connects to twitch chat
#   -Each channel is a server sending Joels (equivalent to random numbers)
#   -calculates how far apart the Joels are
#   -if they are far apart = high Joel variance
#   -if they are close = low Joel variance
#   -PROBLEM : how to calculate the variance of the Joels if only one channel is live ?
#   -SOLUTION : Create Joels from last stream for each tracked channels (joelCount / streamDuration)
