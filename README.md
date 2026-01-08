# WordPress-spam-user-list
A list of well-known spam registration users that can be used to black-list them in various ways

Why I created this list?
I'm a sys admin. So the repo serves a very specefic pupose, I recieved a wordpress that had 200k~ registered users with only aroun 500 legit ones, so I had to find a filtering strategy that would eradicate spam registred users. 
The website also had 70k~ comments mostly spam so I had to create the spam filter keyword list.

In order to find the emails that aren't legit I had to create a script to find them then I added them to the list of spam domains. 

Then the cleanup script will look for keywords and domains and delete them from the directory of websites on the ubuntu server. 

You should be careful after you run the `wp-unusual-email-finder.sh` as it may include your domains. I'm working on a mechanism, but who know!
