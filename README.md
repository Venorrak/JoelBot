# Joel bot
#### This twitch bot made in ruby for the sole purpose of tracking the number of time each user has said Joel in the chat of the selected channels

![Joel](Images/Joel.gif)

# How to start the bot on your side
First you need to clone this repository on your local machine.

## Register your bot on the the developper dashboard
You will need to head to the twitch [developper dashboard](https://dev.twitch.tv/console/apps). Once on the website and connected to your twitch account, click on the "register your application" button.

You will put the name of the bot in the first field, "http://localhost:3000" in the second and choose a category for the bot. Press "save".

You now need to press "manage" on your bot in the list. This will lead to the same page as before but you can now get the client id and the client secret. Save thoses for later.

## Download the required ruby gems for the bot

If you don't have ruby installed, install it.
```
gem install faraday
```
```
gem install mysql2
```
if you have problems downloading the mysql2 gem try
```
sudo apt-get install default-libmysqlclient-dev
```
and try installing the gem again.

## Database setup
I personnaly used mariaDb as my database but I think mysql will work if you have it installed.

If you don't have any DB installed on your computer here is a tutorial on [how to install and setup mariaDb](https://www.digitalocean.com/community/tutorials/how-to-install-mariadb-on-ubuntu-22-04).

Once the installation is done, open the DB.
```
sudo mysql
```
and then run the createDB.sql file.
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

#Channels tracked by the bot
@channels = ["jakecreatesstuff", "venorrak", "lcolonq"]

#Name of the bot on the IRC
@nickname = "venorrak"
```
You can changed wich words will be considered Joel by the bot in the array named "@joels" int the global variables.

## Run it
Open a terminal and run the "joelScan.rb".
```
ruby joelScan.rb
```
Then follow the instructions.