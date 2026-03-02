This is a really simple addon that answers the question, how long till I reach the next lvl.
What is does it figures out how much xp you are getting per second and uses this to give you a time to next lvl. It has been accurate for me on both a new  lvl 1 and my lvl 61.

Every time you gain XP it will simply add the amount of time left to the chat window. If the time is increasing it means you are slowing down and should kill faster or move to a new area. 

I use it to figure out how much time I need to log before the weekend so I can join my guild in dungeons.

How to use:
/xpt
/xpt help

It also tracks gold so type /ct to see how much gold you've made in the past hour.


I am always looking for suggestions and feature requests so don’t be shy to contact me at addon (at) phansoft.ca,
-----

And now a description written by an AI because I think it's cool

The code appears to be written in the Lua programming language, and it is part of a World of Warcraft addon. The code defines a number of functions and variables, and sets up event listeners that trigger these functions when certain events occur in the game.

The first section of the code defines some global variables and sets their initial values. These include the xpt and xpt_frame tables, as well as the wasinparty and xpt_character_data_defaults variables.

The xpt_frame variable is a Frame object in the WoW UI, which is used to register event listeners and attach scripts that will be executed when those events are triggered. The xpt_frame object registers listeners for several different events, including ADDON_LOADED, PLAYER_XP_UPDATE, GROUP_ROSTER_UPDATE, and others.

The xpt table contains functions that are called when these events are triggered. For example, when the ADDON_LOADED event occurs, the xpt.ADDON_LOADED function will be executed. This function is defined later in the code and performs tasks related to loading the addon and initializing its data.

The xp_util table contains a number of utility functions that are used by the xpt functions. These include functions for converting time and money values to different formats, as well as a function for handling user input in the form of slash commands.

Overall, the code appears to be part of a complex addon for World of Warcraft that provides various features and functionality related to experience points, party management, and other game mechanics.
