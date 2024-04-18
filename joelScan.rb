#In order for this to work you need to first register your app/bot on this page : https://dev.twitch.tv/console/apps
#Then you need to get the client id and client secret from the app you created
#You also need to setup a mysql database with the tables in the createDB.sql file
#Create a user that the bot can use for the DB
#In order for this file to work you need to install ruby and the gems in the gemfile

#@client_id = "your client id"
#@clientSecret = "your client secret"

#nickname of the bot
@nickname = "joelscrapper"

#channel to connect to
#all lowercase
# "#" before channel name is required
#@channel = "#venorrak"
#@channel = "#jakecreatesstuff,#hawkthegamer15"
@channel = "#yourchannel"

require "bundler/inline"
require "json"
require "pp"
require "socket"
require "date"

gemfile do
    source "http://rubygems.org"
    gem "faraday"
    gem "mysql2"
end

require "faraday"
require "mysql2"
require_relative "credentials.rb"





#connect to the database
@client = Mysql2::Client.new(:host => "localhost", :username => "bot", :password => "joel")
@client.query("USE joelScan;")

#connect to the server for authentication
$server = Faraday.new(url: "https://id.twitch.tv") do |conn|
    conn.request :url_encoded
end

#open socket to the irc server
@socket = TCPSocket.new('irc.chat.twitch.tv', 6667)

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

def getAccess()
    oauthToken = nil
    #check if there is a token that can be used in the database
    @client.query("SELECT * FROM connectionTokens WHERE TIMESTAMPDIFF(MINUTE, ADDTIME(creationTime, availableTime), '#{DateTime.now.strftime("%Y-%m-%d %H:%M:%S")}') <= 0;").each do |row|
        oauthToken = row["token"]
        tokenid = row["id"]
        @client.query("SELECT TIMESTAMPDIFF(MINUTE, ADDTIME(creationTime, availableTime), '#{DateTime.now.strftime("%Y-%m-%d %H:%M:%S")}') as 'remainingTime' FROM connectionTokens WHERE id = #{tokenid};").each do |row2|
            p "token expires in #{row2["remainingTime"]} minutes"
        end
    end
    #if there is no token that can be used in the database create a new one
    if oauthToken == nil
        response = $server.post("/oauth2/device") do |req|
            req.headers["Content-Type"] = "application/x-www-form-urlencoded"
            req.body = "client_id=#{@client_id}&scopes=chat:read+chat:edit+user:bot+user:write:chat+channel:bot"
        end
        rep = JSON.parse(response.body)
        device_code = rep["device_code"]

        # wait for user to authorize the app
        puts "Please go to #{rep["verification_uri"]} and enter the code #{rep["user_code"]}"
        puts "Press enter when you have authorized the app"
        wait = gets.chomp

        response = $server.post("/oauth2/token") do |req|
            req.body = "client_id=#{@client_id}&scope=channel:manage:broadcast&device_code=#{device_code}&grant_type=urn:ietf:params:oauth:grant-type:device_code"
        end
        rep = JSON.parse(response.body)
        oauthToken = rep["access_token"]

        timeUntilExpire = rep["expires_in"]
        #convert seconds to time
        seconds = timeUntilExpire % 60
        minutes = (timeUntilExpire / 60) % 60
        hours = timeUntilExpire / 3600
        timeString = "#{hours}:#{minutes}:#{seconds}"
        p "token expires in #{timeString}"
        p DateTime.now.strftime("%Y-%m-%d %H:%M:%S")
        p oauthToken
        @client.query("INSERT INTO connectionTokens VALUES (DEFAULT, '#{oauthToken}', '#{timeString}', '#{DateTime.now.strftime("%Y-%m-%d %H:%M:%S")}');");
    end
    loginIRC(oauthToken)
end

def refreshAccess()
    response = $server.post("/oauth2/token") do |req|
        req.body = "client_id=#{@client_id}&client_secret=#{@clientSecret}&grant_type=refresh_token&refresh_token=#{refreshToken}"
    end
    rep = JSON.parse(response.body)
    oauthToken = rep["access_token"]
    refreshToken = rep["refresh_token"]
    timeUntilExpire = rep["expires_in"]
    #convert seconds to hours
    p "token expires in #{timeUntilExpire / 3600} hours"
    loginIRC(oauthToken)
end

def loginIRC(oauthToken)
    @running = true
    @socket.puts("CAP REQ :twitch.tv/membership twitch.tv/tags twitch.tv/commands")
    p "CAP REQ :twitch.tv/membership twitch.tv/tags twitch.tv/commands"
    @socket.puts("PASS oauth:#{oauthToken}")
    p "PASS oauth:#{oauthToken}"
    @socket.puts("NICK #{@nickname}")
    p "NICK #{@nickname}"
    @socket.puts("JOIN #{@channel}")
    p "JOIN #{@channel}"
end

getAccess()

while @running do
    #is the socket readable
    #readable = IO.select([socket], nil, nil, 5)
    readable = IO.select([@socket])
    if readable
        #read the message
        message = @socket.gets
        if message != nil
            #messages are separated by \r\n
            message = message.split("\r\n") rescue nil
            #parse the message
            message.each do |m|
                message = parseMessage(m)
            end

            puts ""
            print "#{message[:command][:command]} #{message[:source][:user]}: "
            puts message[:params][:message]

            messageWords = Array.new
            #if there is a message
            if message[:params][:message] != nil
                #split the message into words
                message[:params][:message].split(' ').each do |word|
                    #if a word is Joel
                    if word == "Joel"
                        #get the user name of the person who said Joel
                        name = message[:source][:user]
                        p "Joel found in message from #{name}"
                        userExits = false
                        #sql request to search if user is in the database
                        @client.query("SELECT * FROM users WHERE name = '#{name}';").each do |row|
                            userExits = true
                            user_id = row["id"]
                            #increment the count of the user
                            @client.query("UPDATE joels SET count = count + 1 WHERE user_id = #{user_id};")
                        end
                        #if user is not in the database
                        if userExits == false
                            user_id = 0
                            #add the user to the database
                            @client.query("INSERT INTO users VALUES (DEFAULT, '#{name}', '#{DateTime.now.strftime("%Y-%m-%d")}');")
                            #get the id of the new user
                            @client.query("SELECT id FROM users WHERE name = '#{name}';").each do |row|
                                user_id = row["id"]
                            end
                            #add the user to the joels table and set the count to 1
                            @client.query("INSERT INTO joels VALUES (DEFAULT, #{user_id}, 1);")
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
                #if the first word is !JoelCount to get the count of a user
                if messageWords[0] == "!JoelCount"
                    #get the username as the second word
                    user = messageWords[1] rescue nil
                    targetChannel = message[:command][:channel]
                    if user == nil
                        #show commands
                        @socket.puts("PRIVMSG #{targetChannel} : for now the only command is !JoelCount <username> to get the count of a user")
                    else
                        userExits = false
                        #search the database for the user
                        @client.query("SELECT count FROM joels WHERE user_id = (SELECT id FROM users WHERE name = '#{user}');").each do |row|
                            count = row["count"].to_i
                            userExits = true
                            #send the count to the channel
                            @socket.puts("PRIVMSG #{targetChannel} :#{user} has said Joel #{count} times")
                        end
                        if userExits == false
                            #if the user is not in the database
                            @socket.puts("PRIVMSG #{targetChannel} :#{user} has not said Joel yet")
                        end
                    end
                end
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
            if message[:command][:command] == "RECONNECT"
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
            refreshAccess()
        end
    end
end


