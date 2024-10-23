# Joel bot
#### This twitch bot made in ruby for the sole purpose of tracking the number of time each user has said Joel in the chat of the selected channels

![Joel](Images/Joel.gif)
<hr>

#### This bot has 3 iterations
- joelScan.rb uses an IRC connection to communicate with twitch servers and does not have commands. WARNING, if you choose to use this version be aware that it's not being updated and lacks many feature of recent versions
- joelScan_v2.rb uses the twitch EventSub solution to communicate with servers, uses events to know when a channel goes live ([this limits the number of tracked channels to 3](https://dev.twitch.tv/docs/eventsub/manage-subscriptions/#subscription-limits))
- joelScan_v3.rb is the same as v2 but goes back to using polling to know when a channel goes live or offline



# How to start the bot on your machine
First you need to clone this repository on your local machine.

This tutorial assumes that you will be using the **V3**

## Register your bot on the the developper dashboard
You will need to head to the twitch [developper dashboard](https://dev.twitch.tv/console/apps). Once on the website and connected to your twitch account, click on the "register your application" button.

You will put the name of the bot in the first field, "http://localhost:3000" in the second and choose a category for the bot. Press "save".

You now need to press "manage" on your bot in the list. This will lead to the same page as before but you can now get the client id and the client secret. Save thoses for later.

## Download the required ruby gems for the bot

If you don't have ruby installed, install it.
```
gem install faraday
gem install awesome_print
gem install faye-websocket
gem install eventmachine
gem install absolute_time
```
```
gem install mysql2
```
if you have problems downloading the mysql2 gem try
```
sudo apt-get install default-libmysqlclient-dev
```
and try installing the gem mysql2 again.

## Database setup
I personnaly used mariaDb as my database but I think mysql will work if you have it installed.

If you don't have any DB installed on your computer here is a tutorial on [how to install and setup mariaDb](https://www.digitalocean.com/community/tutorials/how-to-install-mariadb-on-ubuntu-22-04).

Once the installation is done, open the DB.
Then run the createDB.sql file.
```
source createDB.sql
```
The DB should be good to go.

## Final setup
Now create a new file in the "bot" directory named "credentials.rb".

Inside, write the following content with the corresponding data.
```
#client id
@client_id = "client id"

#client secret
@clientSecret = "client secret"

#Name of the bot on the IRC
#Only needed if using the v1 
@nickname = "venorrak"
```
You can change which words will be considered Joel by the bot in the array named "$acceptedJoels" in the global variables.

"$followedChannels" is an array of the names of tracked channels
```
$followedChannels = ["jakecreatesstuff", "venorrak", "lcolonq", "prodzpod", "cr4zyk1tty", "tyumici"]
```

"$commandChannels" is an array of the names of the channels where the commands will be available
```
$commandChannels = ["venorrak", "prodzpod", "cr4zyk1tty", "jakecreatesstuff", "tyumici", "lcolonq"]
```

## Run it
Open a terminal and run the "joelScan_v3.rb".
```
ruby joelScan_v3.rb
```
Then follow the instructions.