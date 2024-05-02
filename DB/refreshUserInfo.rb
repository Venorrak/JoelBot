require "bundler/inline"
require "json"

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

#connect to the twitch api
$APItwitch = Faraday.new(url: "https://api.twitch.tv") do |conn|
    conn.request :url_encoded
end

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
oauthToken = rep["access_token"]
@APItoken = rep["access_token"]

users = @client.query("SELECT * FROM users").to_a
nbOfUsers = users.length
nbStatus = 0

until users.empty?
    batch = users.shift(99)
    response = $APItwitch.get("/helix/users") do |req|
        req.headers["Accept"] = "*/*"
        req.headers["Authorization"] = "Bearer #{@APItoken}"
        req.headers["Client-Id"] = @client_id
        req.params = { login: batch.map { |user| user["name"] } }
    end
    rep = JSON.parse(response.body)
    rep["data"].each do |user|
        nbStatus += 1
        puts "Updating #{user["login"]} - #{nbStatus}/#{nbOfUsers}"
        pfp = user["profile_image_url"]
        bgp = user["offline_image_url"]
        twitch_id = user["id"]
        #update user
        @client.query("UPDATE pictures SET url = '#{pfp}' WHERE id = (SELECT pfp_id FROM users WHERE name = '#{user["login"]}' LIMIT 1) AND type = 'pfp'")
        @client.query("UPDATE pictures SET url = '#{bgp}' WHERE id = (SELECT bgp_id FROM users WHERE name = '#{user["login"]}' LIMIT 1) AND type = 'bgp'")
        @client.query("UPDATE users SET twitch_id = '#{twitch_id}' WHERE name = '#{user["login"]}'")
    end
end