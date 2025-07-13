require "bundler/inline"
require "json"
require 'eventmachine'
require 'absolute_time'
require "awesome_print"
require 'faye/websocket'
require 'irb'
require 'time'

gemfile do
  source "https://rubygems.org"
  gem "faraday"
  gem "mysql2"
end

require 'faraday'
require 'mysql2'
require_relative "credentials.rb"
require_relative "colorString.rb"

$online = false

$twitch_token = nil
$joinedChannels = []
$acceptedJoels = [
  "Joel", 
  "JoelCheck", 
  "Joeling",
  "Joelest", 
  "JoelJams", 
  "JoelbutmywindowsXPiscrashing", 
  "jol", 
  "GoldenJoel", 
  "Joeler", 
  "JoelPride", 
  "Joel2", 
  "Joll", 
  "JOELLINES", 
  "LetHimJoel", 
  "WhoLetHimJoel", 
  "EvilJoel", 
  "JUSSY", 
  "JoelTrain", 
  "BarrelJoel", 
  "JoelWide1", 
  "JoelWide2", 
  "Joeling2", 
  "PauseJoel", 
  "OhNoWhatHappenedToJoel", 
  "JoelNOPERS", 
  "leoJ", 
  "Joelene"
]
$followedChannels = [
  "jakecreatesstuff", 
  "venorrak", 
  "lcolonq", 
  "prodzpod", 
  "cr4zyk1tty", 
  "tyumici",
  "colinahscopy_", 
  "mickynoon", 
  "bamo16",
  "kinskyunplugged"
]
$commandChannels = [
  "venorrak", 
  "prodzpod", 
  "cr4zyk1tty", 
  "jakecreatesstuff", 
  "tyumici", 
  "lcolonq", 
  "colinahscopy_", 
  "bamo16",
  "kinskyunplugged"
]
$lastJoels = []
$lastStreamJCP = []
$twoMinWait = AbsoluteTime.now
$initiationDateTime = Time.new()
$me_twitch_id = nil
$twitch_session_id = nil
$JCP = 0
$lastLongJCP = nil
$lastShortJCP = nil
$bus = nil

$TokenService = Faraday.new(url: 'http://localhost:5002') do |conn|
  conn.request :url_encoded
end

$SQLService = Faraday.new(url: 'http://localhost:5001') do |conn|
  conn.request :url_encoded
end

$twitch_api = Faraday.new(url: 'https://api.twitch.tv') do |conn|
  conn.request :url_encoded
end

$ntfy_server = Faraday.new(url: 'https://ntfy.venorrak.dev') do |conn|
  conn.request :url_encoded
end


def getTwitchToken()
  begin
    response = $TokenService.get("/token/twitch") do |req|
      req.headers["Authorization"] = $twitch_safety_string
    end
    rep = JSON.parse(response.body)
    $twitch_token = rep["token"]
  rescue
    puts "Token Service is down"
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
    message = "[🐟] #{message}"
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

def getLiveChannels()
  liveChannels = []
  channelsString = ""
  #https://dev.twitch.tv/docs/api/reference/#get-streams
  $followedChannels.each do |channel|
    response = $twitch_api.get("/helix/streams?user_login=#{channel}") do |req|
        req.headers["Authorization"] = "Bearer #{$twitch_token}"
        req.headers["Client-Id"] = @client_id
    end

    if response.status == 401
      getTwitchToken()
      return response.body
    end

    begin
      rep = JSON.parse(response.body)
    rescue
      return nil
    end

    if rep.nil? || rep["data"].nil?
      return response.body
    end

    rep["data"].each do |stream|
      if stream["type"] == "live"
        liveChannels << "#{stream["user_login"]}"
      end
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

  if response.status == 401
    getTwitchToken()
    return nil
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
  totalJoelCountLastStream = sendQuery("GetTotalJoelCountLastStream", [channelName])["count"].to_i rescue 0
  result = totalJoelCountLastStream / totalMinutes rescue 0
  if result == Float::INFINITY
    return 0
  end
  return result
end

def updateJCP()

  joelString = $lastJoels.join("")
  joelStringCodepoints = joelString.codepoints
  
  # averageJCP = 100 * (1 - (allAverageJoelPerMinute.max - allAverageJoelPerMinute.min) / allAverageJoelPerMinute.max)
  extremes = []
  2.times do
    extremes << joelStringCodepoints.shuffle[0]
  end
  $JCP = 100 * (1 - (extremes.max.to_f - extremes.min.to_f) / extremes.max.to_f)
  if $JCP == 100
    $JCP = 99.99
  end

  # printJCPStatus()
end

def printJCPStatus()
  puts ""
  puts "JCP : #{$JCP.round(2)}%".blue
  barString = "["
  $JCP.to_i.times do
    barString += "="
  end
  (100 - $JCP).to_i.times do
    barString += " "
  end
  barString += "]"
  puts barString
  puts ""
end

def updateJCPDB()
  begin
    if $lastLongJCP.nil?
      $lastLongJCP = sendQuery("GetLastLongJCP", [])
    end
    if $lastShortJCP.nil?
      $lastShortJCP = sendQuery("GetLastShortJCP", [])
    end

    if Time.now - Time.parse($lastLongJCP["timestamp"]) > 60
      sendQuery("NewJCPlong", [$JCP, Time.now.strftime('%Y-%m-%d %H:%M:%S')])
      $lastLongJCP = {
        "JCP" => $JCP,
        "timestamp" => Time.now.strftime('%Y-%m-%d %H:%M:%S')
      }
      
      # delete old data in JCPshort where the timestamp is older than 24 hours
      sendQuery("DeleteOldShortJCP", [(Time.now - 86400).strftime('%Y-%m-%d %H:%M:%S')])
    end
    if Time.now - Time.parse($lastShortJCP["timestamp"]) > 15
      sendQuery("NewJCPshort", [$JCP, Time.now.strftime('%Y-%m-%d %H:%M:%S')])
      $lastShortJCP = {
        "JCP" => $JCP,
        "timestamp" => Time.now.strftime('%Y-%m-%d %H:%M:%S')
      }
    end

    
  rescue => exception
    puts exception
  end
end

def createEmptyDataForLastJoel()
  10.times do
    $lastJoels << $acceptedJoels.shuffle[0]
  end
end

def updateTrackedChannels()
  begin
    liveChannels = getLiveChannels()
  rescue
    liveChannels = []
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
          $joinedChannels << {:channel => channel, :subscription_id => subscribeData["data"][0]["id"], :subscription_time => Time.now}
          # send_twitch_message(channel, "JoelBot has entered the chat, !JoelCommands for commands")
          sendNotif("Bot joined #{channel}", "Alert Bot Joined Channel")
        rescue => exception
          puts exception
          p subscribeData
          p $joinedChannels
          sendNotif("Error subscribing to channel #{channel}", "Alert Bot Error")
          exit()
        end
      end
      #if the channel is not live and the bot is in the channel
      if !liveChannels.include?(channel) && joinedChannelsName.include?(channel)
        leavingChannel = $joinedChannels.find { |channelData| channelData[:channel] == channel }
        unsubscribeToTwitchEventSub(leavingChannel[:subscription_id])
        $joinedChannels.delete(leavingChannel)
        # send_twitch_message(channel, "JoelBot has left the chat")
        sendNotif("Bot left #{channel}", "Alert Bot Left Channel")
      end
    end
  end
end

def getTwitchUser(name)
  response = $twitch_api.get("/helix/users?login=#{name}") do |req|
      req.headers["Authorization"] = "Bearer #{$twitch_token}"
      req.headers["Client-Id"] = @client_id
  end
  begin
    if response.status == 401
      getTwitchToken()
      return nil
    end

    rep = JSON.parse(response.body)
  rescue
    rep = nil
    getTwitchToken()
  end
  return rep
end

def sendNotif(message, title)
  rep = $ntfy_server.post("/JoelBot") do |req|
      req.headers["host"] = "ntfy.venorrak.dev"
      req.headers["Priority"] = "5"
      req.headers["Title"] = title
      req.body = message
  end
end

def createUserDB(name, userData, startJoels)
  begin
    pfp = nil
    bgp = nil
    twitch_id = nil
    user_id = 0
    pfp_id = 0
    bgp_id = 0
    if userData.nil?
      return
    end
    userData["data"].each do |user|
        twitch_id = user["id"]
        pfp = user["profile_image_url"]
        bgp = user["offline_image_url"]
    end

    sendQuery("NewPfp", [pfp])
    sendQuery("NewBgp", [bgp])
    
    pfp_id = sendQuery("GetPicture", [pfp])["id"]
    bgp_id = sendQuery("GetPicture", [bgp])["id"]

    sendQuery("NewUser", [twitch_id, pfp_id, bgp_id, name, DateTime.now.strftime("%Y-%m-%d")])

    #get the id of the new user
    user_id = sendQuery("GetUser", [name])["id"]

    #add the user to the joels table and set the count to 1
    sendQuery("NewJoel", [user_id, startJoels])
  rescue => exception
    p exception
    sendNotif("Error creating user in the database", "Alert")
  end
end

def createChannelDB(channelName)
  channel_id = 0
  begin
    #add the channel to the database
    sendQuery("NewChannel", [channelName, DateTime.now.strftime("%Y-%m-%d")])

    #get the id of the new channel
    channel_id = sendQuery("GetChannel", [channelName])["id"]

    #add the channel to the channelJoels table and set the count to 1
    sendQuery("NewChannelJoels", [channel_id])
  rescue => exception
    p exception
    sendNotif("Error creating channel in the database", "Alert")
  end
end

def joelReceived(receivedData, nbJoel, thisLastJoel)
  userName = receivedData["payload"]["event"]["chatter_user_login"]
  channelName = receivedData["payload"]["event"]["broadcaster_user_login"]

  $lastJoels.shift
  $lastJoels << thisLastJoel

  begin
    #check if the user is in the database
    if !sendQuery("GetUser", [userName]).nil?
      sendQuery("UpdateJoel", [nbJoel, userName])
    else
      createUserDB(userName, getTwitchUser(userName), nbJoel)
    end
    #check if the channel is in the database
    if !sendQuery("GetChannel", [channelName]).nil?
      sendQuery("UpdateChannelJoels", [nbJoel, channelName])
    else
      createChannelDB(channelName)
    end
    #check if the channel owner is in the database
    if sendQuery("GetUser", [channelName]).nil?
      createUserDB(channelName, getTwitchUser(channelName), 0)
    end
    #check if the stream is in the database
    if !sendQuery("GetStreamJoelsToday", [channelName, DateTime.now.strftime("%Y-%m-%d")]).nil?
      sendQuery("UpdateStreamJoels", [nbJoel, channelName, DateTime.now.strftime("%Y-%m-%d")])
    else
      sendQuery("NewStreamJoels", [channelName, DateTime.now.strftime("%Y-%m-%d")])
    end

    #check if the User Joel stream is in the database
    if !sendQuery("GetStreamUserJoels", [channelName, userName, DateTime.now.strftime("%Y-%m-%d")]).nil?
      sendQuery("UpdateStreamUserJoels", [nbJoel, channelName, userName, DateTime.now.strftime("%Y-%m-%d")])
    else
      sendQuery("NewStreamUserJoels", [channelName, DateTime.now.strftime("%Y-%m-%d"), userName, nbJoel])
    end
    
  rescue => exception
    puts exception
  end
end

def treatCommands(words, receivedData)
  chatterName = receivedData["payload"]["event"]["chatter_user_login"]
  channelId = receivedData["payload"]["event"]["broadcaster_user_id"]
  broadcastName = receivedData["payload"]["event"]["broadcaster_user_login"]
  begin
    if $commandChannels.include?(broadcastName)
      case words[0].downcase
      when "!joelcount", "!jcount", "!jc"
        if words[1] != "" && words[1] != nil
          username = words[1]
          count = sendQuery("GetUserCount", [username.downcase])
          if !count.nil?
            count = count["count"].to_i
            send_twitch_message(channelId.to_i, "#{username} has Joel'd #{count} times")
          else
            send_twitch_message(channelId.to_i, "#{username} didn't Joel yet")
          end
        else
          count = sendQuery("GetUserCount", [chatterName.downcase])
          if !count.nil?
            count = count["count"].to_i
            send_twitch_message(channelId.to_i, "#{chatterName} has Joel'd #{count} times")
          else
            send_twitch_message(channelId.to_i, "#{chatterName} didn't Joel yet")
          end
        end
      when "!joelcountchannel", "!jcountchannel", "!jcc"
        if words[1] != "" && words[1] != nil
          channelName = words[1]
          count = sendQuery("GetChannelJoels", [channelName.downcase])
          if !count.nil?
            count = count["count"].to_i
            send_twitch_message(channelId.to_i, "Joel count on #{channelName} is #{count}")
          else
            send_twitch_message(channelId.to_i, "no Joel on #{channelName} channel yet")
          end
        else
          count = sendQuery("GetChannelJoels", [broadcastName.downcase])
          if !count.nil?
            count = count["count"].to_i
            send_twitch_message(channelId.to_i, "Joel count on #{broadcastName} is #{count}")
          else
            send_twitch_message(channelId.to_i, "no Joel on this channel yet")
          end
        end
      when "!joelcountstream", "!jcountstream", "!jcs"
        count = sendQuery("GetStreamJoelsToday", [broadcastName.downcase, DateTime.now.strftime("%Y-%m-%d")])
        if !count.nil?
          count = count["count"].to_i
          send_twitch_message(channelId.to_i, "Joel count on this stream is #{count}")
        else
          send_twitch_message(channelId.to_i, "no Joel today yet")
        end
      when "!joeltop", "!jtop", "!jt"
        users = sendQuery("GetTop5Joels", [])
        message = ""
        users.each_with_index do |user, index|
          message += "#{user["name"]} : #{user["count"].to_i} | "
        end
        send_twitch_message(channelId.to_i, message)
      when "!joeltopchannel", "!jtopchannel", "!jtc"
        channels = sendQuery("GetTop5JoelsChannel", [])
        message = ""
        channels.each_with_index do |channel, index|
          message += "#{channel["name"]} : #{channel["count"].to_i} | "
        end
        send_twitch_message(channelId.to_i, message)
      when "!joelcommands", "!jcommands"
        send_twitch_message(channelId.to_i, "!JoelCount [username] / !JoelCountChannel [channelname] / !JoelCountStream / !JoelTop / !JoelTopChannel / !joelStats [username] / !jcp / !ping / !joelDrawer / !joelChannels / !joelLive")
      when "!joelstats", "!jstats", "!js"
        if words[1] != "" && words[1] != nil
          username = words[1]
        else
          username = chatterName
        end
        if sendQuery("GetUserArray", [username.downcase]).size > 0
          basicStats = sendQuery("GetBasicStats", [username.downcase])
          mostJoelStreamStats = sendQuery("GetMostJoelStreamStats", [username.downcase])
          mostJoeledStreamerStats = sendQuery("GetMostJoeledStreamerStats", [username.downcase])

          message = "#{username} has Joel'd #{basicStats["totalJoels"].to_i} times since #{basicStats["firstJoelDate"]} / "
          message += "Most Joels in a stream : #{mostJoelStreamStats["mostJoelsInStream"]} on #{mostJoelStreamStats["mostJoelsInStreamDate"]} on #{mostJoelStreamStats["MostJoelsInStreamStreamer"]} / "
          message += "Most Joeled streamer : #{mostJoeledStreamerStats["count"]} on #{mostJoeledStreamerStats["mostJoeledStreamer"]}"
          send_twitch_message(channelId.to_i, message)
        else
          send_twitch_message(channelId.to_i, "#{username} didn't Joel yet")
        end
      when "!jcp"
        send_twitch_message(channelId.to_i, "JCP : #{$JCP.round(2)}%")
      when "!ping"
        send_twitch_message(channelId.to_i, "Joel Pong")
      when "!pong"
        send_twitch_message(channelId.to_i, "Joel Ping")
      when "!joeldrawer", "!jdraw", "!jd"
        index = rand(0..$acceptedJoels.size - 1)
        send_twitch_message(channelId.to_i, "@#{chatterName} - #{index.to_roman} - #{$acceptedJoels[index]}")
      when "!joelchannels", "!jchannels"
        send_twitch_message(channelId.to_i, "Channels with JoelBot : #{$followedChannels.join(", ")}")
      when "!joellive", "!jlive", "!jl"
        send_twitch_message(channelId.to_i, "Live channels with JoelBot : #{$joinedChannels.map { |channel| channel[:channel] }.join(", ")}")
      end
    end
  rescue => exception
    puts exception
  end
end

class Integer
  def to_roman
    result = ""
    value_map = {
      1000 => "M", 900 => "CM", 500 => "D", 400 => "CD",
      100 => "C", 90 => "XC", 50 => "L", 40 => "XL",
      10 => "X", 9 => "IX", 5 => "V", 4 => "IV", 1 => "I"
    }
    num = self
    value_map.each do |value, roman|
      while num >= value
      result << roman
      num -= value
      end
    end
    if result == ""
      return "0"
    end
    result
  end
end

def sendQuery(queryName, body)
  response = $SQLService.post("/joel/#{queryName}") do |req|
    req.headers['Content-Type'] = 'application/json'
    req.body = body.to_json
  end
  case response.status
  when 200
    return JSON.parse(response.body)
  when 400, 404
    throw 'bad request or server rebooting'
  when 500
    throw "SQL Service Error"
  end
end

def createMSG(subject, payload)
  return {
    "subject": subject.join("."),
    "payload": payload
  }
end

def sendToBus(msg)
  if msg.is_a?(Hash)
    msg = msg.to_json
  end
  $bus.send(msg)
end

getTwitchToken()
if $twitch_token.nil?
  puts "error getting twitch token"
  exit
end
$me_twitch_id = getTwitchUser("venorrak")["data"][0]["id"]
if $me_twitch_id.nil?
  puts "error getting my twitch id"
  exit
end
createEmptyDataForLastJoel()

Thread.start do
  EM.run do
    bus = Faye::WebSocket::Client.new('ws://192.168.0.16:5000')
    $bus = bus
  
    bus.on :open do |event|
      p [:open, "BUS"]
      $bus = bus
    end
  
    bus.on :message do |event|
      begin
        data = JSON.parse(event.data)
      rescue
        data = event.data
      end
  
      if data["subject"] == "token.twitch" && data["payload"]["status"] == "refreshed"
        getTwitchToken()
      end
    end
  
    bus.on :error do |event|
      p [:error, event.message, "BUS"]
    end
  
    bus.on :close do |event|
      p [:close, event.code, event.reason, "BUS"]
    end
  end
end

def startWebsocket(url, isReconnect = false)
  EM.run do
    ws = Faye::WebSocket::Client.new(url)

    ws.on :open do |event|
      p [:open, "twitch", Time.now().to_s.split(" ")[1]]
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
              $joinedChannels << {:channel => channel, :subscription_id => subscribeData["data"][0]["id"], :subscription_time => Time.now}
              if isReconnect == false
                # send_twitch_message(channel, "JoelBot has entered the chat, !JoelCommands for commands")
                sendNotif("Bot joined #{channel}", "Alert Bot Joined Channel")
              end
            rescue => exception
              puts exception
              p subscribeData
              p $joinedChannels
              sendNotif("Error subscribing to channel #{channel}", "Alert Bot Error")
              exit()
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
          words = message.delete_suffix("\u{E0000}").strip.split(" ")
          treatCommands(words, receivedData)
          nbJoelInMessage = 0
          thislastJoel = nil
          words.each do |word|
            if $acceptedJoels.include?(word)
              thislastJoel = word
              nbJoelInMessage += 1
            end
          end
          if nbJoelInMessage > 0
            #if the message is not sent by the bot
            if receivedData["payload"]["event"]["chatter_user_login"] == "venorrak" && words[0] == "[📺]"
              print("")
            else
              joelReceived(receivedData, nbJoelInMessage, thislastJoel)
              sendToBus(createMSG(["joel", "received"], {
                "channel" => receivedData["payload"]["event"]["broadcaster_user_login"],
                "user" => receivedData["payload"]["event"]["chatter_user_login"],
                "count" => nbJoelInMessage,
                "type" => thislastJoel,}))
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

loop do
  begin
    sleep(1)
    now = AbsoluteTime.now
    updateJCP()
    updateJCPDB()
    if now - $twoMinWait > 120
      updateTrackedChannels()
      $twoMinWait = now
    end
  rescue => exception
    puts "------------------------"
    puts exception
    puts "------------------------"
  end
end