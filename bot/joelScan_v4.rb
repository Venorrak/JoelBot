require "bundler/inline"
require "json"
require 'eventmachine'
require "awesome_print"
require 'faye/websocket'
require 'time'


gemfile do
  source "https://rubygems.org"
  gem "faraday"
end

require_relative "credentials.rb"

$token = nil
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
$trackedChannels = [
  "jakecreatesstuff", 
  "venorrak", 
  "lcolonq", 
  "prodzpod", 
  "cr4zyk1tty", 
  "tyumici",
  "colinahscopy_", 
  "mickynoon", 
  "bamo16",
  "kinskyunplugged",
  "badcop_",
  "lala_amanita",
  "liquidcake1",
  "saladforrest",
  "just_jane",
  "yiffweed",
  "bigbookofbug"
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
$JCP = 0
$lastLongJCP = nil
$lastShortJCP = nil
$bus = nil
$me_twitch_id = nil
$messageQueue = []

$TokenService = Faraday.new(url: 'http://token:5002') do |conn|
  conn.request :url_encoded
end

$SQLService = Faraday.new(url: 'http://sql:5001') do |conn|
  conn.request :url_encoded
end

$twitch_api = Faraday.new(url: 'https://api.twitch.tv') do |conn|
  conn.request :url_encoded
end

def getToken()
  begin
    response = $TokenService.get("/token/twitch")
    rep = JSON.parse(response.body)
    $twitch_token = rep["token"]
  rescue => e
    p e
    puts "Token Service is down"
    exit(1)
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
    puts "SQL Service Error"
    exit(1)
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

def createEmptyDataForLastJoel()
  10.times do
    $lastJoels << $acceptedJoels.shuffle[0]
  end
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

def send_twitch_message(channel, message, reply_to_id=nil)
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
        "message": message,
        "reply_parent_message_id": reply_to_id
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

def subscribeToChannelChat(session_id, streamer_twitch_id)
  data = {
      "type" => "channel.chat.message",
      "version" => "1",
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

def processJoelInMessage(message, nbJoel, lastJoel)
    $lastJoels.shift
    $lastJoels << lastJoel

    userName = message["chatter_user_login"]
    userId = message["chatter_user_id"]
    channelName = message["broadcaster_user_login"]

    begin
        #check if the user is in the database
        if !sendQuery("GetUser", [userName]).nil?
            sendQuery("UpdateJoel", [nbJoel, userName])
        else
            createUserDB(userName, userId, nbJoel)
        end
        #check if the channel is in the database
        if !sendQuery("GetChannel", [channelName]).nil?
            sendQuery("UpdateChannelJoels", [nbJoel, channelName])
        else
            createChannelDB(channelName)
        end
        #check if the channel owner is in the database
        if sendQuery("GetUser", [channelName]).nil?
            createUserDB(channelName, userId, 0)
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
    rescue => e
        puts "get better at sql buddy"
        puts e
    end
end

def treatCommands(message)
    chatterName = message["chatter_user_login"]
    channelId = message["broadcaster_user_id"]
    broadcastName = message["broadcaster_user_login"]
    reply_to_id = message["message_id"]
    words = message["message"]["text"].delete_suffix("\u{E0000}").delete_suffix("\u034F").strip.split(" ")
    case words[0].downcase
    when "!joelcount", "!jcount", "!jc"
        username = words[1]
        if username.nil? || username.strip == ""
            username = chatterName
        end
        count = sendQuery("GetUserCount", [username.downcase])
        if !count.nil?
          count = count["count"].to_i
          send_twitch_message(channelId.to_i, "Joel count for #{username} is #{count}", reply_to_id)
        else
          send_twitch_message(channelId.to_i, "#{username} has no Joel yet", reply_to_id)
        end
    when "!joelcountchannel", "!jcountchannel", "!jcc"
        channelName = words[1]
        if channelName.nil? || channelName.strip == ""
            channelName = broadcastName
        end
        count = sendQuery("GetChannelJoels", [channelName.downcase])
        if !count.nil?
          count = count["count"].to_i
          send_twitch_message(channelId.to_i, "Joel count on #{channelName} is #{count}", reply_to_id)
        else
          send_twitch_message(channelId.to_i, "no Joel yet on #{channelName}", reply_to_id)
        end
    when "!joelcountstream", "!jcountstream", "!jcs"
        count = sendQuery("GetStreamJoelsToday", [broadcastName.downcase, DateTime.now.strftime("%Y-%m-%d")])
        if !count.nil?
          count = count["count"].to_i
          send_twitch_message(channelId.to_i, "Joel count on this stream is #{count}", reply_to_id)
        else
          send_twitch_message(channelId.to_i, "no Joel today yet", reply_to_id)
        end
    when "!joeltop", "!jtop", "!jt"
        users = sendQuery("GetTop5Joels", [])
        message = ""
        users.each_with_index do |user, index|
          message += "#{user["name"]} : #{user["count"].to_i} | "
        end
        send_twitch_message(channelId.to_i, message, reply_to_id)
    when "!joeltopchannel", "!jtopchannel", "!jtc"
        channels = sendQuery("GetTop5JoelsChannel", [])
        message = ""
        channels.each_with_index do |channel, index|
          message += "#{channel["name"]} : #{channel["count"].to_i} | "
        end
        send_twitch_message(channelId.to_i, message, reply_to_id)
    when "!jcp"
        send_twitch_message(channelId.to_i, "JCP : #{$JCP.round(2)}%", reply_to_id)
    when "!ping"
        send_twitch_message(channelId.to_i, "Joel Pong", reply_to_id)
    when "!joeldrawer", "!jdraw", "!jd"
        index = rand(0..$acceptedJoels.size - 1)
        send_twitch_message(channelId.to_i, "#{index.to_roman} - #{$acceptedJoels[index]}", reply_to_id)
    end
end

def processMessage(message)
    joel_in_message = 0
    lastJoel = ''
    $acceptedJoels.each do |joel_variant|
        nb = message["message"]["text"].downcase.scan(joel_variant.downcase).length
        joel_in_message += nb
        if nb > 0
            lastJoel = joel_variant
        end
    end
    if joel_in_message > 0
        processJoelInMessage(message, joel_in_message, lastJoel)
        sendToBus(createMSG(["joel", "received"], {
            "channel" => message["broadcaster_user_login"],
            "user" => message["chatter_user_login"],
            "count" => joel_in_message}))
    end
    if message["message"]["text"].start_with?("!") && $commandChannels.include?(message["broadcaster_user_login"])
      treatCommands(message)
    end
end

# MAIN
getToken()
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

# BUS Thread
Thread.start do
  EM.run do
    bus = Faye::WebSocket::Client.new('ws://bus:5000')
    $bus = bus
  
    bus.on :open do |event|
      p [:open, "BUS"]
      $bus = bus
    end
  
    bus.on :message do |event|
      begin
        data = JSON.parse(event.data)
      rescue
        throw "invalid json on bus"
      end
  
      if data["subject"] == "token.twitch" && data["payload"]["status"] == "refreshed"
        getToken()
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

# twitch eventsub
Thread.start do
    EM.run do
        ws = Faye::WebSocket::Client.new("wss://eventsub.wss.twitch.tv/ws?keepalive_timeout_seconds=30")

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

            if receivedData["metadata"]["message_type"] == "session_reconnect"
                puts "twitch requested reconnect"
                exit(1)
            end

            if receivedData["metadata"]["message_type"] == "session_welcome"
                twitch_session_id = receivedData["payload"]["session"]["id"]
                $trackedChannels.each do |channel|
                    begin
                        subscribeToChannelChat(twitch_session_id, getTwitchUser(channel)["data"][0]["id"])
                    rescue => e
                        p e
                        puts "error subscribing to eventsub for #{channel}"
                    end
                end
            end

            if receivedData["metadata"]["message_type"] == "notification"
                case receivedData["payload"]["subscription"]["type"]
                when "channel.chat.message"
                    puts "#{receivedData["payload"]["event"]["broadcaster_user_login"]} - #{receivedData["payload"]["event"]["chatter_user_login"]}: #{receivedData["payload"]["event"]["message"]["text"]}"
                    $messageQueue.push(receivedData["payload"]["event"])
                end
            end

        end

        ws.on :close do |event|
            p [Time.now().to_s.split(" ")[1], :close, event.code, event.reason, "twitch"]
            exit(1)
        end
    end
end

loop do
    begin
        updateJCP()
        updateJCPDB()
        message = $messageQueue.shift
        if !message.nil?
            processMessage(message)
        end
        sleep(0.5)
    rescue => exception
        puts "------------------------"
        puts Time.now.to_s + " - " + exception.to_s
        puts "------------------------"
    end
end