#In order for this to work you need to first register your app/bot on this page : https://dev.twitch.tv/console/apps
#Then you need to get the client id and client secret from the app you created
#You also need to setup a mysql database with the tables in the createDB.sql file
#Create a user that the bot can use for the DB
#In order for this file to work you need to install ruby and the gems in the gemfile


# create a file named credentials.rb in the same directory as this file with the following content uncommented and filled in
# --------------------------------------credentials.rb-----------------------------------------
#@client_id = "your client id"
#@clientSecret = "your client secret"

#nickname of the bot
#@nickname = "something"
# ------------------------------------------end of file-----------------------------------------


#----------------------------------------------------------------------------------------------
#-----------------------------------required gems and libraries--------------------------------
#----------------------------------------------------------------------------------------------
require "bundler/inline"
require "json"
require "pp"
require "socket"
require "date"
require 'absolute_time'
require 'awesome_print'

gemfile do
    source "http://rubygems.org"
    gem "faraday"
    gem "mysql2"
end

require "faraday"
require "mysql2"
require_relative "credentials.rb"

#----------------------------------------------------------------------------------------------
#---------------------------------------global variables---------------------------------------
#----------------------------------------------------------------------------------------------

#token to access the API and IRC
@APItoken = nil
#channels currently live and joined
@joinedChannels = []
#token to refresh the access token
@refreshToken = nil
#array of joels to search for in the messages
@joels = ["GoldenJoel" , "Joel2" , "Joeler" , "Joel" , "jol" , "JoelCheck" , "JoelbutmywindowsXPiscrashing" , "JOELLINES", "Joeling", "Joeling", "LetHimJoel", "JoelPride", "WhoLetHimJoel", "Joelest", "EvilJoel", "JUSSY", "JoelJams", "JoelTrain", "BarrelJoel", "JoelWide1", "JoelWide2", "Joeling2"]
#array of channels to track (lowercase)
@channels = ["jakecreatesstuff", "venorrak", "lcolonq", "prodzpod", "cr4zyk1tty", "tyumici"]
#last time refresh was made
@lastRefresh = AbsoluteTime.now

#------------------------------------------------------------------------------------------------
# ----------------------------connect to the different services----------------------------------
#------------------------------------------------------------------------------------------------

#connect to the database
@client = Mysql2::Client.new(:host => "localhost", :username => "bot", :password => "joel")
@client.query("USE joelScan;")

#connect to the server for authentication
$server = Faraday.new(url: "https://id.twitch.tv") do |conn|
    conn.request :url_encoded
end

#connect to the twitch api
$APItwitch = Faraday.new(url: "https://api.twitch.tv") do |conn|
    conn.request :url_encoded
end

#open socket to the irc server
@socket = TCPSocket.new('irc.chat.twitch.tv', 6667)

#connect to my ntfy server
$NTFYDerver = Faraday.new(url: "https://ntfy.venorrak.dev") do |conn|
    conn.request :url_encoded
end

#-------------------------------------------------------------------------------------------------
# ----------------------------------functions and methods-----------------------------------------
#-------------------------------------------------------------------------------------------------

#parse the message from the irc server
#original parser in javascript https://dev.twitch.tv/docs/irc/example-parser/
#for this parser I just looked at what the final result should look like and made it work
#DONT LOOK IT'S UGLY
def parseMessage(message) 
    parsedMessage = {
        tags: {},
        source: {},
        command: {},
        params: {}
    }
    if message.start_with?(":")
        message = message.delete_prefix(":")
        if message.start_with?("tmi.twitch.tv")
            parsedMessage[:source][:server] = message[0].split(' ')[0]
            parsedMessage[:command][:command] = message[0].split(' ')[1]
            parsedMessage[:command][:channel] = message[0].split(' ')[2]
            parsedMessage[:params][:message] = message[1]
        else
            if message.split(' ').count > 3
                #chui tanne
            else
                parsedMessage[:source][:user] = message.split('!')[0]
                parsedMessage[:source][:host] = message.split('!')[1].split(' ')[0]
                parsedMessage[:command][:command] = message.split(' ')[1]
                parsedMessage[:command][:channel] = message.split(' ')[2]
            end
        end
    else
        message = message.split(':')
        message[0] = message[0].delete_prefix('@')
        finalEmote = 1
        rawTags = message[0].split(';')
        rawTags.each do |t|
            if t.split('=')[0] == "emotes"
                stringEmotes = "#{t.split('=')[1]}"
                count = 0
                for mess in message do
                    count += 1
                    if mess.include?(";")
                        finalEmote = count
                    end
                end
                if finalEmote >= 3
                    stringEmotes += ":"
                end
                finalEmote.times do |e|
                    if message[e + 1].include?(";")
                        stringEmotes += ":#{message[e + 1].split(";")[0]}"
                        break
                    end
                    stringEmotes += message[e + 1]
                end
                parsedMessage[:tags]["#{t.split('=')[0]}"] = stringEmotes
                message[finalEmote - 1] = message[finalEmote - 1].delete_prefix("#{stringEmotes.split(":").last};")
            else
                parsedMessage[:tags]["#{t.split('=')[0]}"] = t.split('=')[1]
            end
        end
        rawTags = message[finalEmote - 1].split(';')
        rawTags.each do |t|
            parsedMessage[:tags]["#{t.split('=')[0]}"] = t.split('=')[1]
        end
        

        

        if message[1].start_with?("tmi.twitch.tv")
            parsedMessage[:source][:server] = message[1].split(' ')[0]
            parsedMessage[:command][:command] = message[1].split(' ')[1]
        else
            afterTags = 0
            message.count.times do |i|
                lookForSource = message[i].include?("tmi.twitch.tv")
                if lookForSource == true
                    afterTags = i
                    break
                end
            end

            messageIndex = afterTags + 1
            messageLength = message.count - afterTags - 1

            parsedMessage[:source][:user] = message[afterTags].split('!')[0]
            parsedMessage[:source][:host] = message[afterTags].split('!')[1].split(' ')[0] rescue nil
            parsedMessage[:command][:command] = message[afterTags].split(' ')[1]
            parsedMessage[:command][:channel] = message[afterTags].split(' ')[2]
            mes = ""
            messageLength.times do |i|
                mes += ":#{message[i + messageIndex]}"
            end
            mes = mes.delete_prefix(":")
            parsedMessage[:params][:message] = mes
        end
        
    end
    return parsedMessage
end

#function to send a notification to the ntfy server on JoelBot subject
def sendNotif(message, title)
    rep = $NTFYDerver.post("/JoelBot") do |req|
        req.headers["host"] = "ntfy.venorrak.dev"
        req.headers["Priority"] = "5"
        req.headers["Title"] = title
        req.body = message
    end
    pp rep.body
end

#function to get the access token for API and IRC
def getAccess()
    oauthToken = nil
    #https://dev.twitch.tv/docs/authentication/getting-tokens-oauth/#device-code-grant-flow
    response = $server.post("/oauth2/device") do |req|
        req.headers["Content-Type"] = "application/x-www-form-urlencoded"
        req.body = "client_id=#{@client_id}&scopes=chat:read+chat:edit+user:bot+user:write:chat+channel:bot+user:manage:whispers"
    end
    rep = JSON.parse(response.body)
    device_code = rep["device_code"]

    # wait for user to authorize the app
    puts "Please go to #{rep["verification_uri"]} and enter the code #{rep["user_code"]}"
    puts "Press enter when you have authorized the app"
    wait = gets.chomp

    #https://dev.twitch.tv/docs/authentication/getting-tokens-oauth/#authorization-code-grant-flow
    response = $server.post("/oauth2/token") do |req|
        req.body = "client_id=#{@client_id}&scopes=channel:manage:broadcast,user:manage:whispers&device_code=#{device_code}&grant_type=urn:ietf:params:oauth:grant-type:device_code"
    end
    rep = JSON.parse(response.body)
    @APItoken = rep["access_token"]
    @refreshToken = rep["refresh_token"]

    timeUntilExpire = rep["expires_in"]
    #convert seconds to time
    seconds = timeUntilExpire % 60
    minutes = (timeUntilExpire / 60) % 60
    hours = timeUntilExpire / 3600
    timeString = "#{hours}:#{minutes}:#{seconds}"
    p "token expires in #{timeString}"
    loginIRC(@APItoken)
end

#function to refresh the access token for API and IRC
def refreshAccess()
    @client = nil
    @client = Mysql2::Client.new(:host => "localhost", :username => "bot", :password => "joel")
    @client.query("USE joelScan;")

    #https://dev.twitch.tv/docs/authentication/refresh-tokens/#how-to-use-a-refresh-token
    response = $server.post("/oauth2/token") do |req|
        req.headers["Content-Type"] = "application/x-www-form-urlencoded"
        req.body = "grant_type=refresh_token&refresh_token=#{@refreshToken}&client_id=#{@client_id}&client_secret=#{@clientSecret}"
    end
    rep = JSON.parse(response.body)
    @APItoken = rep["access_token"]
    @refreshToken = rep["refresh_token"]
    loginIRC(@APItoken)
end

#function to get the live channels from the channels array
def getLiveChannels()
    liveChannels = []
    channelsString = ""
    #https://dev.twitch.tv/docs/api/reference/#get-streams
    @channels.each do |channel|
        response = $APItwitch.get("/helix/streams?user_login=#{channel}") do |req|
            req.headers["Authorization"] = "Bearer #{@APItoken}"
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

#function to login to the IRC server
def loginIRC(oauthToken)
    #close the socket and open a new one
    @socket.close
    @socket = nil
    @socket = TCPSocket.new('irc.chat.twitch.tv', 6667)
    @running = true
    #send the login information to the server
    #https://dev.twitch.tv/docs/irc/authenticate-bot/#sending-the-pass-and-nick-messages
    @socket.puts("CAP REQ :twitch.tv/membership twitch.tv/tags twitch.tv/commands")
    p "CAP REQ :twitch.tv/membership twitch.tv/tags twitch.tv/commands"
    @socket.puts("PASS oauth:#{oauthToken}")
    p "PASS oauth:#{oauthToken}"
    @socket.puts("NICK #{@nickname}")
    p "NICK #{@nickname}"
    #join the channels that are live
    liveChannels = getLiveChannels()
    liveChannels.each do |channel|
        @socket.puts("JOIN ##{channel}")
        @joinedChannels << channel
    end
end

#function to print the message in a clean way   
def printClean(message)
    puts ""
    print "#{message[:command][:command]} #{message[:source][:user]}: "
    puts message[:params][:message]
end

#function to get the user info from the API
def getTwitchUser(name)
    p "getTwitchUser"
    response = $APItwitch.get("/helix/users?login=#{name}") do |req|
        req.headers["Authorization"] = "Bearer #{@APItoken}"
        req.headers["Client-Id"] = @client_id
    end
    begin
        rep = JSON.parse(response.body)
    rescue
        rep = {}
    end
    return rep
end

#function to send a whisper
def sendWhisper(from, to, message)
    p "sending whisper"
    response = $APItwitch.post("/helix/whispers?from_user_id=#{from}&to_user_id=#{to}") do |req|
        req.headers["Authorization"] = "Bearer #{@APItoken}"
        req.headers["Client-Id"] = @client_id
        req.headers["Content-Type"] = "application/json"
        req.body = {"message": message}.to_json
    end
    p response.body
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
    @client.query("INSERT INTO pictures VALUES (DEFAULT, '#{pfp}', 'pfp');")
    @client.query("INSERT INTO pictures VALUES (DEFAULT, '#{bgp}', 'bgp');")
    
    pfp_id = @client.query("SELECT id FROM pictures WHERE url = '#{pfp}';").first["id"]
    bgp_id = @client.query("SELECT id FROM pictures WHERE url = '#{bgp}';").first["id"]
    @client.query("INSERT INTO users VALUES (DEFAULT, '#{twitch_id}', '#{pfp_id}', '#{bgp_id}', '#{name}', '#{DateTime.now.strftime("%Y-%m-%d")}');")
    #get the id of the new user
    @client.query("SELECT id FROM users WHERE name = '#{name}';").each do |row|
        user_id = row["id"]
    end
    #add the user to the joels table and set the count to 1
    @client.query("INSERT INTO joels VALUES (DEFAULT, #{user_id}, #{startJoels});")
end

#create a channel and channelJoels in the database
def createChannelDB(channelName)
    channel_id = 0
    #add the channel to the database
    @client.query("INSERT INTO channels VALUES (DEFAULT, '#{channelName}', '#{DateTime.now.strftime("%Y-%m-%d")}');")
    #get the id of the new channel
    @client.query("SELECT id FROM channels WHERE name = '#{channelName}';").each do |row|
        channel_id = row["id"]
    end
    #add the channel to the channelJoels table and set the count to 1
    @client.query("INSERT INTO channelJoels VALUES (DEFAULT, #{channel_id}, 1);")

    #register the channel owner to the user database if it doesn't exist
    channelOwnerExists = false
    #sql request to search if user is in the database
    @client.query("SELECT * FROM users WHERE name = '#{channelName}';").each do |row|
        channelOwnerExists = true
    end
    return channelOwnerExists
end

#---------------------------------------------------------------------------------------------
#--------------------------------------main code----------------------------------------------
#---------------------------------------------------------------------------------------------

#get the access token for the API and IRC
getAccess()

#get the bot id from the API
#https://dev.twitch.tv/docs/api/reference/#get-users
rep = getTwitchUser(@nickname)
@me_id = rep["data"][0]["id"]

#thread to join and part channels that are live
Thread.start do
    loop do
        # each 2 minutes check if the channels are live and if the bot is in the channels
        sleep 120
        p "checking channels"
        begin
            liveChannels = getLiveChannels()
        rescue
            sendNotif("Bot stopped checking channels", "Alert")
        end
        @channels.each do |channel|
            #if the channel is live and the bot is not in the channel
            if liveChannels.include?(channel) && !@joinedChannels.include?(channel)
                @socket.puts("JOIN ##{channel}")
                sendNotif("Bot joined ##{channel}", "Alert Bot Joined Channel")
                p "JOIN ##{channel}"
                @joinedChannels << channel
            end
            #if the channel is not live and the bot is in the channel
            if !liveChannels.include?(channel) && @joinedChannels.include?(channel)
                sendNotif("Bot left ##{channel}", "Alert Bot Left Channel")
                @socket.puts("PART ##{channel}")
                p "PART ##{channel}"
                @joinedChannels.delete(channel)
            end
        end
    end
    sendNotif("Bot stopped checking channels", "Alert")
end

#main loop
while @running do
    #refresh connection each 2 hours
    now = AbsoluteTime.now
    if (now - @lastRefresh) >= 7200
        refreshAccess()
        @lastRefresh = now
    end
    #is the socket readable
    readable = IO.select([@socket], nil, nil, 1) rescue nil
    if readable
        #read the message
        message = @socket.gets
        if message != nil
            #messages are separated by \r\n
            message = message.split("\r\n") rescue nil
            #parse the message
            message.each do |m|
                message = parseMessage(m)
                printClean(message)
            end

            messageWords = Array.new
            #if there is a message
            if message[:params][:message] != nil
                #split the message into words
                message[:params][:message].split(' ').each do |word|
                    #if a word is Joel
                    if @joels.include?(word)
                        #get the user name of the person who said Joel
                        name = message[:source][:user]
                        p "Joel found in message from #{name}"
                        userExits = false
                        channelExists = false
                        #sql request to search if user is in the database
                        @client.query("SELECT * FROM users WHERE name = '#{name}';").each do |row|
                            userExits = true
                            user_id = row["id"]
                            #increment the count of the user
                            @client.query("UPDATE joels SET count = count + 1 WHERE user_id = #{user_id};")
                        end
                        #sql request to search if channel is in the database
                        @client.query("SELECT * FROM channels WHERE name = '#{message[:command][:channel].delete_prefix("#")}';").each do |row|
                            channelExists = true
                            channel_id = row["id"]
                            #increment the count of the channel
                            @client.query("UPDATE channelJoels SET count = count + 1 WHERE channel_id = #{channel_id};")
                            if channelExists
                                streamJoelsExists = false
                                #add joel to streamJoels of today if it exists or create it
                                @client.query("SELECT * FROM streamJoels WHERE channel_id = #{channel_id} AND streamDate = '#{DateTime.now.strftime("%Y-%m-%d")}';").each do |row|
                                    streamJoelsExists = true
                                    streamJoels_id = row["id"]
                                    @client.query("UPDATE streamJoels SET count = count + 1 WHERE id = #{streamJoels_id};")
                                end
                                if !streamJoelsExists
                                    @client.query("INSERT INTO streamJoels VALUES (DEFAULT, #{channel_id}, 1, '#{DateTime.now.strftime("%Y-%m-%d")}');")
                                end
                            end
                        end
                        #if user is not in the database
                        if userExits == false
                            #add the user to the database
                            rep = getTwitchUser(name)
                            createUserDB(name, rep, 1)
                        end
                        #if channel is not in the database
                        if channelExists == false
                            channelName = message[:command][:channel].delete_prefix("#")

                            channelOwnerExists = createChannelDB(channelName)
                            
                            if channelOwnerExists == false
                                rep = getTwitchUser(channelName)
                                createUserDB(channelName, rep, 0)
                                sendNotif("New channel added to the database: #{channelName}", "Alert New Channel")
                            end
                        end
                    end
                    #if the word is not empty or nil
                    if word != "" && word != nil && word != " "
                        #add the word to the messageWords array
                        messageWords.push(word)
                    end
                end
            end
            #if message is 2 words long
            if messageWords.length <= 2
                #if the server sends a PING message
                if messageWords[0] == "PING"
                    #send a PONG message back
                    @socket.puts("PONG :#{message[1]}")
                    p "\n PONG :#{message[1]}"
                end
            end
            if message[:command][:command] == "NOTICE"
                print "NOTICE : "
                p message[:params][:message]
            end
            #the server sends a RECONNECT message when it needs to terminate the connection
            if message[:command][:command] == "RECONNECT"
                sendNotif("TWITCH IRC needs to terminate connection for maintenance", "Alert Reconnect in 15 minutes")
                p "TWITCH IRC needs to terminate connection for maintenance"
                p "Reconnecting in 15 minutes"
                sleep 900
                p "Reconnecting"
                refreshAccess()
            end
            if message[:command][:command] == "USERSTATE" || message[:command][:command] == "ROOMSTATE"
                pp message
            end
            if message[:tags].key?("PING ")
                @socket.puts("PONG :#{message[:source][:server]}")
                p "PONG :#{message[:source][:server]}"
            end
        else
            p "message is nil"
            sleep 5
            refreshAccess()
        end
    end
end
