-- Author      : jjacob
-- Create Date : 2008/01/18
-- Updated	   : 2015/01/03


local xpt = {};
local xpt_global_data_defaults = {};
local xpt_character_data_defaults = {};
local xpt_frame = CreateFrame("Frame");
local wasinparty = false;
xpt_frame:RegisterEvent("ADDON_LOADED");
xpt_frame:RegisterEvent("PLAYER_XP_UPDATE");
xpt_frame:RegisterEvent("PLAYER_LOGIN");
xpt_frame:RegisterEvent("PLAYER_MONEY");
-- new event for tracking non-gold currencies
xpt_frame:RegisterEvent("CURRENCY_DISPLAY_UPDATE");

xpt_frame:RegisterEvent("GROUP_ROSTER_UPDATE");
xpt_frame:RegisterEvent("LFG_PROPOSAL_SUCCEEDED");
xpt_frame:RegisterEvent("LFG_COMPLETION_REWARD");

xpt_frame:SetScript("OnEvent",
function(self,event,...) 
	if xpt[event] and type(xpt[event]) == "function" then
		return xpt[event](xpt,...)
	end
end)


local xp_util = {}

function xp_util.to_hms(seconds)
  hours = math.floor (seconds / 3600);
  seconds = seconds - (hours * 3600);
  minutes = math.floor (seconds / 60);
  seconds = math.floor (seconds - (minutes * 60));
  return hours,minutes,seconds;
end --to_hms

function xp_util.to_hms_string(seconds)
  return string.format("%d:%.2d:%.2d", xp_util.to_hms(seconds));
end --to_hms_string


function xp_util.to_gsc(copper)
	local positive = 1;
	if copper < 0 then
		positive = -1;
	end
	copper = copper * positive;
	gold = math.floor (copper / 10000);
	copper = copper - (gold * 10000);
	silver = math.floor (copper / 100);
	copper = math.floor (copper - (silver * 100));
	return gold,silver,copper;
end --to_hms

function xp_util.to_gsc_string(copper)
  local ret = string.format("|cffFFD700%dG|r |cffC0C0C0%dS|r |cffB87333%dC|r", xp_util.to_gsc(copper));
  if (copper < 0) then
	ret = "-" .. ret;
  end
  return ret;
end

--[[
    UI helpers and currency tracking
]]

-- frame that shows xp %, estimated time and recent currency gains
local xpt_ui_frame

local function create_ui()
    local frame = CreateFrame("Frame","XP_Timer_UI_Frame",UIParent)
    frame:SetSize(200,24)
    frame:SetPoint("CENTER",0,0)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            -- remember position
            local point, relativeTo, relPoint, xOfs, yOfs = self:GetPoint()
            xpt_global_data.ui_point = point
            xpt_global_data.ui_relPoint = relPoint
            xpt_global_data.ui_xOfs = xOfs
            xpt_global_data.ui_yOfs = yOfs
        end)

    local bar = CreateFrame("StatusBar", nil, frame)
    bar:SetAllPoints(true)
    bar:SetStatusBarTexture("Interface\\TARGETINGFRAME\\UI-StatusBar")
    bar:GetStatusBarTexture():SetHorizTile(false)
    bar:SetMinMaxValues(0, 100)
    bar:SetValue(0)
    bar:SetStatusBarColor(0.0,0.5,1.0)

    local text = bar:CreateFontString(nil,"OVERLAY","GameFontNormal")
    text:SetPoint("CENTER",0,0)
    text:SetJustifyH("CENTER")

    -- The old "GameFontSmall" template can taint in newer clients and may not exist;
    -- use a modern small font object or set the font manually as a fallback.
    local goldtext = frame:CreateFontString(nil,"OVERLAY")
    if GameFontNormalSmall then
        goldtext:SetFontObject(GameFontNormalSmall)
    else
        -- final fallback: specify a default font and size
        goldtext:SetFont("Fonts\FRIZQT__.TTF", 10)
    end
    goldtext:SetPoint("TOP", frame, "BOTTOM", 0, -2)
    goldtext:SetJustifyH("CENTER")

    frame.bar = bar
    frame.text = text
    frame.goldtext = goldtext

    if xpt_global_data.ui_point then
        frame:ClearAllPoints()
        frame:SetPoint(xpt_global_data.ui_point, UIParent, xpt_global_data.ui_relPoint,
                       xpt_global_data.ui_xOfs, xpt_global_data.ui_yOfs)
    end

    frame.elapsed = 0
    frame:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + elapsed
        if self.elapsed >= 1 then
            self.elapsed = 0
            xpt:update_ui()
        end
    end)

    return frame
end

function xpt:update_ui()
    if not xpt_ui_frame then return end
    local xp_cur = UnitXP("player")
    local xp_max = UnitXPMax("player")
    local pct = 0
    if xp_max > 0 then pct = xp_cur / xp_max * 100 end
    xpt_ui_frame.bar:SetValue(pct)
    local time_left = 0
    local time_diff = GetTime() - self.start_time
    local xp_per_second = 0
    if time_diff > 0 then
        xp_per_second = self.xp_gained / time_diff
        if xp_per_second > 0 then
            -- if player has gained XP since last UI update, recalc base
            -- otherwise just tick down the previous estimate
            local now = GetTime()
            if xp_cur ~= self.last_xp_for_ui or self.time_left == 0 then
                time_left = (xp_max - xp_cur) / xp_per_second
            else
                -- decrement by elapsed wall time
                time_left = self.time_left - (now - self.last_ui_update_time)
                if time_left < 0 then time_left = 0 end
            end

            self.time_left = time_left
            self.last_ui_update_time = now
            self.last_xp_for_ui = xp_cur
        end
    end

    -- only append the ETA when we have a positive rate (i.e. XP has been
    -- earned since the reset); otherwise just show percentage alone
    local line = string.format("%.1f%%", pct)
    if xp_per_second > 0 then
        line = line .. "  " .. xp_util.to_hms_string(time_left)
    end
    xpt_ui_frame.text:SetText(line)

    -- gold in last 5 minutes
    local now = GetTime()
    local gold5 = 0
    if xpt_character_data.gold_events then
        for i=#xpt_character_data.gold_events,1,-1 do
            local ev = xpt_character_data.gold_events[i]
            if now - ev.time <= 300 then
                gold5 = gold5 + ev.diff
            else
                if now - ev.time > 86400 then
                    table.remove(xpt_character_data.gold_events, i)
                end
            end
        end
    end
    local goldstr = xp_util.to_gsc_string(gold5)

    local currencies = {}
    if xpt_character_data.currency_history then
        local sums = {}
        for i=#xpt_character_data.currency_history,1,-1 do
            local ev = xpt_character_data.currency_history[i]
            if now - ev.time <= 300 then
                sums[ev.name] = (sums[ev.name] or 0) + ev.diff
            elseif now - ev.time > 86400 then
                table.remove(xpt_character_data.currency_history,i)
            end
        end
        for name, amt in pairs(sums) do
            table.insert(currencies, string.format("%s %+d", name, amt))
        end
    end
    local curstr = ""
    if #currencies>0 then
        curstr = table.concat(currencies, "  ")
    end
    local display = "Gold 5m: "..goldstr
    if curstr~="" then display = display.."  "..curstr end
    xpt_ui_frame.goldtext:SetText(display)
end

function xpt:trackCurrencies()
    if not xpt_character_data.currency_last_amounts then
        xpt_character_data.currency_last_amounts = {}
    end
    if not xpt_character_data.currency_history then
        xpt_character_data.currency_history = {}
    end
    local n = C_CurrencyInfo.GetCurrencyListSize()
    for i=1,n do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info and not info.isHeader then
            local id = info.currencyTypesID or info.currencyID
            local currency = C_CurrencyInfo.GetCurrencyInfo(id)
            if currency then
                local amount = currency.quantity or 0
                local last = xpt_character_data.currency_last_amounts[id] or amount
                local diff = amount - last
                if diff ~= 0 then
                    table.insert(xpt_character_data.currency_history,{time=GetTime(),id=id,name=info.name,diff=diff})
                    xpt_character_data.currency_last_amounts[id] = amount
                end
            end
        end
    end
end

function xpt:CURRENCY_DISPLAY_UPDATE(...)
    xpt:trackCurrencies()
    xpt:update_ui()
end


-- Check if we join a party/raid.
-- Thank you skada for the inspiration
local function check_for_join_and_leave()
	if IsInGroup() and wasinparty == false then -- if nil this is first check after reload/relog
		-- We joined a raid/party.
		-- remember this time
		DEFAULT_CHAT_FRAME:AddMessage("You are in a group /xpt party to see a report")
		 xpt:party_start()
	end

	if not IsInGroup() and wasinparty then
		DEFAULT_CHAT_FRAME:AddMessage("You left a group")
		xpt:party()
		xpt:party_end()
	end
	-- Mark our last party status.
	wasinparty = not not IsInGroup()
end

function xpt:handle_slashes(msg)
  local command, rest = msg:match("^(%S*)%s*(.-)$");
				--DEFAULT_CHAT_FRAME:AddMessage("^"..command.."^");
				--DEFAULT_CHAT_FRAME:AddMessage(rest);
				if command == "" then
					self:default();
				else
					if self[command] and type(self[command]) == "function"  then
						return self[command](self,rest)
					else
					   DEFAULT_CHAT_FRAME:AddMessage("Unknown Command");
					end
				end
end



--local old_xp,start_time,xp_gained,xp_diff

function xpt:ADDON_LOADED(...)
	local addon = ...
	if addon == "xp_timer" then
		if type(xpt_global_data) ~= "table" then
			xpt_global_data  = xpt_global_data_defaults;
		end
		if type(xpt_character_data) ~= "table" then
			xpt_character_data  = xpt_character_data_defaults;
		end
		if not SlashCmdList["XPTIMER"] then -- make sure we don't overwrite default if Blizz decides to use same name
				SlashCmdList["XPTIMER"] = function(msg)
				   xpt:handle_slashes(msg);
				end -- end function
				SLASH_XPTIMER1 = "/xpt";
				SLASH_XPTIMER2 = "/xp_timer";
		end -- end if 
		if not SlashCmdList["CASHTIMER"] then -- make sure we don't overwrite default if Blizz decides to use same name
				SlashCmdList["CASHTIMER"] = function(msg)
				   xpt:ct(msg);
				end -- end function
				SLASH_CASHTIMER1 = "/ct";
				SLASH_CASHTIMER2 = "/cash_timer";
		end -- end if 
	end
end



function xpt:PLAYER_LOGIN(...)
	DEFAULT_CHAT_FRAME:AddMessage("XP Timer loaded. Type '/xpt help' for more information");
	self:cash_timer_setup()
	self:reset();
	-- create floating xp bar UI
	xpt_ui_frame = create_ui()
	-- gather initial currency values so deltas are correct
	self:trackCurrencies()
	self:update_ui()
end

function xpt:PLAYER_XP_UPDATE(...)
	local xp_cur = UnitXP("player");
	
	--Sometimes you get the event twice for a single XP grant
	if (xp_cur  == self.old_xp) then
		--DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00DEBUG no xp gained:|r %d %d",xp_cur),0.38,0.58,0.92);
		return;
	end
	self.xp_diff = xp_cur - self.old_xp;
	--Save this just for if you level as a bit of a hack
	if (self.xp_diff < 0) then -- lvled up
		DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00Congrats on the level up|r"));
		self.xp_diff = 1; -- assume that the xp gained was the same as before, this will quickly factor out over time.
	end
	
	--track total xp gained
	self.xp_gained = self.xp_gained + self.xp_diff;
	-- find amount of time playing
	local time_diff = GetTime() - self.start_time;
	if (time_diff > 0) then -- incase xp is gained instantly upon login divide by zero is not fun
		if (xpt_global_data.show_time_on_xp) then
			local xp_last_checked_time = self.xp_checked_time; -- last time we got XP
			self.xp_checked_time = GetTime();
			local time_since_last_xp = self.xp_checked_time  - xp_last_checked_time;
			local last_estimated_time = self.time_till_next_level - time_since_last_xp; -- estimate minus the time change
			local xp_per_second = self.xp_gained / time_diff;
			self.time_till_next_level = (UnitXPMax("player") - xp_cur) / xp_per_second
			local estimate_inacuracy = last_estimated_time - self.time_till_next_level;
			-- if estimate inaccuracy is > 0 then the person is leveling faster than before if it is negative then they are going slower
			if estimate_inacuracy > 60 then
			-- fast
			DEFAULT_CHAT_FRAME:AddMessage(string.format("Time to next level down to: |cff00ff00%s|r",xp_util.to_hms_string(self.time_till_next_level)),0.38,0.58,0.92);
			else
				if estimate_inacuracy < -60 then
				DEFAULT_CHAT_FRAME:AddMessage(string.format("Time to next level increasing: |cffff0000%s|r kill faster or change zones",xp_util.to_hms_string(self.time_till_next_level)),0.38,0.58,0.92);
				else
				DEFAULT_CHAT_FRAME:AddMessage(string.format("Time to next level: %s",xp_util.to_hms_string(self.time_till_next_level)),0.38,0.58,0.92);
				end
			end
		end
	end -- time has passed:
	self.old_xp = xp_cur;
	-- refresh UI
	self:update_ui()
end

function xpt:default()
    local time_diff = GetTime() - self.start_time;
	DEFAULT_CHAT_FRAME:AddMessage("Time Online: "..xp_util.to_hms_string(time_diff));
	DEFAULT_CHAT_FRAME:AddMessage("XP Gained total: "..self.xp_gained);
	DEFAULT_CHAT_FRAME:AddMessage("XP Last Gained: "..self.xp_diff);
	local xp_per_second = self.xp_gained / time_diff;
	DEFAULT_CHAT_FRAME:AddMessage("XP per second: "..xp_per_second);
	local xp_cur = UnitXP("player");
	local kills_to_lvl = math.ceil((UnitXPMax("player") - xp_cur) / self.xp_diff);
	DEFAULT_CHAT_FRAME:AddMessage("Kills to next level: "..kills_to_lvl);
	DEFAULT_CHAT_FRAME:AddMessage(string.format("Time to next level: |cffff0000%s|r",xp_util.to_hms_string((UnitXPMax("player") - xp_cur) / xp_per_second)));
end


function xpt:hour()
    local time_diff = GetTime() - self.start_time;
	if time_diff >= (3600) then
		local xp_per_hour = (self.xp_gained / time_diff) * 3600;
		DEFAULT_CHAT_FRAME:AddMessage("XP per hour: "..xp_per_hour);
	else
		DEFAULT_CHAT_FRAME:AddMessage("You have not been logged in without a reset for an hour");
		DEFAULT_CHAT_FRAME:AddMessage("Time Logged IN: "..xp_util.to_hms_string(time_diff));
	end
end

function xpt:PLAYER_MONEY(...)
		
	    local current_time = math.floor(GetTime());
		--DEFAULT_CHAT_FRAME:AddMessage("You where paid at "..xp_util.to_hms_string(current_time));
		local cash_time_diff = current_time - self.cash_time_last_paid ;
		self.cash_time_last_paid = current_time;
		xpt_character_data.cash_running_time = xpt_character_data.cash_running_time + cash_time_diff;
		--DEFAULT_CHAT_FRAME:AddMessage("You where last paid "..xp_util.to_hms_string(cash_time_diff).." ago.");
		local current_cash = GetMoney(); 
		local cash_diff = current_cash - self.cash_last_known ;
		self.cash_last_known = current_cash;
		-- record gold change for the 5‑minute UI summary
		if cash_diff ~= 0 then
			xpt_character_data.gold_events = xpt_character_data.gold_events or {}
			table.insert(xpt_character_data.gold_events,{time=GetTime(),diff=cash_diff})
		end
		if xpt_global_data["show_cash_on_earn"] then
			if ( cash_diff > 0) then
				DEFAULT_CHAT_FRAME:AddMessage("You just made "..xp_util.to_gsc_string(cash_diff));
			else
				DEFAULT_CHAT_FRAME:AddMessage("You just lost "..xp_util.to_gsc_string(cash_diff));			
			end
		end
		-- update UI immediately
		self:update_ui()
		--DEFAULT_CHAT_FRAME:AddMessage("You have "..xp_util.to_gsc_string(GetMoney()));
		if (xpt_character_data.cash_values_array[xpt_character_data.cash_running_time] == nil) then
			xpt_character_data.cash_values_array[xpt_character_data.cash_running_time] = cash_diff
		else
			xpt_character_data.cash_values_array[xpt_character_data.cash_running_time] = xpt_character_data.cash_values_array[xpt_character_data.cash_running_time]+ cash_diff;
		end
		--DEFAULT_CHAT_FRAME:AddMessage("You recieved "..xp_util.to_gsc_string(xpt_character_data.cash_values_array[xpt_character_data.cash_running_time]).."this second.");
end


function xpt:ct(msg)
	local command, rest = msg:match("^(%S*)%s*(.-)$");
	if command == "" then
		self:ctdefault();
	elseif command == "on" or command == "off" then
		self:ctdefault(msg);
	else
		if self[command] and type(self[command]) == "function"  then
			return self[command](self,rest)
		else
			self:ctdefault(msg);
		end
	end
end


function xpt:ctdefault(...)
	local timespan = ...;
	local include_timespan  = false;
	if tonumber(timespan) ~= nil then
		include_timespan = true;
		timespan = tonumber(timespan) * 60;
	elseif (timespan == "off") then
		xpt_global_data.show_cash_on_earn = false;
		DEFAULT_CHAT_FRAME:AddMessage("Cash display |cffff0000disabled|r");
	elseif (timespan == "on") then
		xpt_global_data.show_cash_on_earn = true;
		DEFAULT_CHAT_FRAME:AddMessage("Cash display |cff00ff00enabled|r");
	end
	

	
	local current_time = math.floor(GetTime());
	local cash_time_diff = current_time - self.cash_time_last_paid ;
	self.cash_time_last_paid = current_time;
	xpt_character_data.cash_running_time = xpt_character_data.cash_running_time + cash_time_diff;
	local cash_in_last_minute = 0;
	local cash_in_last_hour = 0;
	local cash_in_last_day = 0;
	local cash_in_timespan = 0;
	for cash_time,cash_made in pairs(xpt_character_data.cash_values_array) do
	--DEFAULT_CHAT_FRAME:AddMessage("calculating: "..to_gsc_string(cash_made).." at "..to_hms_string(cash_time));
	 local timeOffset = xpt_character_data.cash_running_time - cash_time
	 if (timeOffset < 300)then
		cash_in_last_minute = cash_in_last_minute + cash_made;
	 end
	 if (timeOffset < 3600) then 
		cash_in_last_hour = cash_in_last_hour + cash_made;		
	 end
	 if (timeOffset < 86400) then
		cash_in_last_day = cash_in_last_day + cash_made;
	 end
	 if (include_timespan and timeOffset <= timespan) then
		cash_in_timespan = cash_in_timespan + cash_made
	 end
	 --memory cleanup
	 if (timeOffset > 86400) then
		table.remove(xpt_character_data.cash_values_array,cash_time);
		--DEFAULT_CHAT_FRAME:AddMessage("cleaned time: "..cash_time,1.0,0.0,0.0);
	 end
	 --done memory cleanup
	end
	--DEFAULT_CHAT_FRAME:AddMessage("Running time: "..xp_util.to_hms_string(xpt_character_data.cash_running_time));
	DEFAULT_CHAT_FRAME:AddMessage("Cash in last 5 minutes: "..xp_util.to_gsc_string(cash_in_last_minute));
	DEFAULT_CHAT_FRAME:AddMessage("Cash in last hour: "..xp_util.to_gsc_string(cash_in_last_hour));
	DEFAULT_CHAT_FRAME:AddMessage("Cash in last day: "..xp_util.to_gsc_string(cash_in_last_day));
	if (include_timespan) then
		DEFAULT_CHAT_FRAME:AddMessage(string.format("Cash in last |cff00ff00%d|r minutes: %s ",timespan/60,xp_util.to_gsc_string(cash_in_timespan)));
	end
end
function xpt:cash(...)
	xpt:ct(...)
end

function xpt:optimize()
	
	for cash_time,cash_made in pairs(cash_values_array) do
		local timeOffset = xpt_character_data.cash_running_time - cash_time
		if (timeOffset > 86400) then
			table.remove(cash_values_array,cash_time);
		end
	end
end

function xpt:reset()
	if (self.start_time ~= nil) then
		DEFAULT_CHAT_FRAME:AddMessage("XP Timer reset");
	end
	self.old_xp = UnitXP("player");
	self.start_time = GetTime(); 
	self.group_start = 0;
	self.xp_checked_time = self.start_time;
	self.time_till_next_level = 86400;
	-- start with no XP gained so the UI won't show an ETA until the
	-- user actually earns experience
	self.xp_gained = 0;
	self.xp_diff = 0;
	-- UI bookkeeping for countdown logic
	self.time_left = 0;
	self.last_ui_update_time = GetTime();
	self.last_xp_for_ui = self.old_xp;
	check_for_join_and_leave();
    if (self.how_time_on_xp == nil) then
        xpt_global_data.show_time_on_xp = true;
	end
end

function xpt:help(msg)
	DEFAULT_CHAT_FRAME:AddMessage("XP Timer Usage:");
	DEFAULT_CHAT_FRAME:AddMessage("/xpt help -- this help");
	DEFAULT_CHAT_FRAME:AddMessage("/xpt -- Get information about the XP you have gained");
	DEFAULT_CHAT_FRAME:AddMessage("(A draggable XP bar also appears on your screen with percentage & time.)");
	DEFAULT_CHAT_FRAME:AddMessage("/xpt reset -- reset your XP timer. great for you leave town or start a dungeon");
	DEFAULT_CHAT_FRAME:AddMessage("/xpt hour -- xp gained average per hour if logged in for more than an hour");
	DEFAULT_CHAT_FRAME:AddMessage("/xpt cash OR /ct -- show how much gold you have gained in the past 24 hours");
	DEFAULT_CHAT_FRAME:AddMessage("/xpt off OR /xpt on -- disable or enable the status message on new XP");
	DEFAULT_CHAT_FRAME:AddMessage("/xpt party OR /xpt group -- Find information on the current group.");
	DEFAULT_CHAT_FRAME:AddMessage("/xpt party_start OR /xpt party_end -- Manually start party tracking.");
	DEFAULT_CHAT_FRAME:AddMessage("/ct time -- How much gold in the last 'time' minutes. Max 24 hours");
	DEFAULT_CHAT_FRAME:AddMessage("/ct on OR /ct off -- turn on (off by default) reports on gold earned to blizzard style");
end

function xpt:cash_timer_setup()
	--DEFAULT_CHAT_FRAME:AddMessage("Cash Timer setup");
	if (xpt_character_data.cash_values_array == nil) then
		xpt_character_data.cash_values_array  = {}; -- first run on install
	end
	if (xpt_character_data.cash_running_time == nil) then
		xpt_character_data.cash_running_time = 0; -- first run on install
	end
	if (xpt_global_data.show_cash_on_earn == nill) then
		xpt_global_data.show_cash_on_earn = false;
	end
	
	self.cash_last_known = GetMoney();
	self.cash_time_last_paid = math.floor(GetTime());
end

function xpt:off()
    xpt_global_data.show_time_on_xp = false;
    self:status();
end


function xpt:on()
    xpt_global_data.show_time_on_xp =  true;
    self:status();
end

function xpt:status()
    if xpt_global_data.show_time_on_xp then
		DEFAULT_CHAT_FRAME:AddMessage("Time updates |cff00ff00will be|r shown every time you gain XP");
	else
		DEFAULT_CHAT_FRAME:AddMessage("Time updates will |cffff0000not|r show every time you gain XP");
	end
	
	if xpt_global_data.show_cash_on_earn then
		DEFAULT_CHAT_FRAME:AddMessage("Cash updates |cff00ff00will be|r shown every time you gain gold");
	else
		DEFAULT_CHAT_FRAME:AddMessage("Cash updates will |cffff0000not|r show every time you gain gold");
	end
end


-- tried to reset timer when a lfg started but it triggered when in a group, just removing for now
--function xpt:LFG_PROPOSAL_SUCCEEDED()
	-- if you where already in a group this is pretty close to when you will start a new LFG
--	DEFAULT_CHAT_FRAME:AddMessage("Restarting group timer for LFG")
--	xpt:party_start()
--end

--LFG is done show a report
function xpt:LFG_COMPLETION_REWARD()
	xpt:party()
end


function xpt:party_start()
	DEFAULT_CHAT_FRAME:AddMessage("Starting Dungeon XP Timer use /xpt party to see a report")
	self.group_start = GetTime()
	--I don't need to track party XP as I can subtract this value later
	self.group_xp_total = self.xp_gained;
end

--reset values
function xpt:party_end()
	self.group_start = 0;
	self.group_xp_total = 0;
	xpt:party();
	DEFAULT_CHAT_FRAME:AddMessage("Ending Dungeon XP Timer")
end


function xpt:party()
	if self.group_start ~= 0 then
		local time_diff = GetTime() - self.group_start;
		DEFAULT_CHAT_FRAME:AddMessage("Time in party: "..xp_util.to_hms_string(time_diff));
		--if there is no party xp then xp is turned off or they have hit max level
		local party_xp = self.xp_gained - self.group_xp_total
		if self.group_xp_total ~= nil and party_xp > 0 then 
				
			DEFAULT_CHAT_FRAME:AddMessage("XP Gained in party: "..party_xp);
			local xp_cur = UnitXP("player");
			local dungeons_to_lvl = math.ceil((UnitXPMax("player") - xp_cur) / party_xp);
			DEFAULT_CHAT_FRAME:AddMessage("Dungeons to next level: "..dungeons_to_lvl);
		end
		local cash_in_party = 0;
		--update the time for cash tracking.
		local current_time = math.floor(GetTime());
		local cash_time_diff = current_time - self.cash_time_last_paid ;
		self.cash_time_last_paid = current_time;
		xpt_character_data.cash_running_time = xpt_character_data.cash_running_time + cash_time_diff;
		for cash_time,cash_made in pairs(xpt_character_data.cash_values_array) do
		 local timeOffset = xpt_character_data.cash_running_time - cash_time
		 if (timeOffset < time_diff)then
			--DEFAULT_CHAT_FRAME:AddMessage(string.format("TimeOffset %s time_diff %s",timeOffset,time_diff));
			--DEFAULT_CHAT_FRAME:AddMessage(string.format("Cash in party: %s ",xp_util.to_gsc_string(cash_in_party)));
			cash_in_party = cash_in_party + cash_made;
			
		 end
		 --memory cleanup
		 if (timeOffset > 86400) then
			table.remove(xpt_character_data.cash_values_array,cash_time);
		 end
		 --done memory cleanup
		end
		if cash_in_party > 0 then
			DEFAULT_CHAT_FRAME:AddMessage(string.format("Cash in party: %s ",xp_util.to_gsc_string(cash_in_party)));
		end
		
	end
end

function xpt:group()
	xpt:party()
end

function xpt:GROUP_ROSTER_UPDATE()
	check_for_join_and_leave()
end

