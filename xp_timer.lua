-- Author      : jjacob
-- Create Date : 2008/01/18
-- Updated	   : 2015/01/03


local xpt = {};
local xpt_global_data_defaults = { show_chat = true, show_ui = true, cash_minute_ui_timeframe = 5 };
local xpt_character_data_defaults = {};
local xpt_frame = CreateFrame("Frame");
local wasinparty = false;


-- helper for controlled chat output
function xpt:print(msg, r, g, b)
    if xpt_global_data.show_chat then
        DEFAULT_CHAT_FRAME:AddMessage(msg, r, g, b)
    end
end

xpt_frame:RegisterEvent("ADDON_LOADED");
xpt_frame:RegisterEvent("PLAYER_XP_UPDATE");
xpt_frame:RegisterEvent("PLAYER_LOGIN");
-- detect entry to dungeon/raid instances
xpt_frame:RegisterEvent("PLAYER_ENTERING_WORLD");
-- reputation tracking removed; we only care about currency now
-- xpt_frame:RegisterEvent("UPDATE_FACTION");
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
    local g,s,c = xp_util.to_gsc(copper)
    local goldIcon = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:0:0|t"
    local silverIcon = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:0:0|t"
    local copperIcon = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:0:0|t"
    local ret = string.format("%d%s %d%s %d%s", g, goldIcon, s, silverIcon, c, copperIcon)
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
    -- use BackdropTemplate for borders
    local frame = CreateFrame("Frame","XP_Timer_UI_Frame",UIParent,"BackdropTemplate")
    -- make room for the gold text underneath the bar
    frame:SetSize(200,24)
    frame:SetPoint("CENTER",0,0)
    frame:SetMovable(true)
    -- give a light border and semi-transparent black background
    frame:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left=2, right=2, top=2, bottom=2 },
    })
    frame:SetBackdropColor(0,0,0,0.4)
    frame:SetBackdropBorderColor(1,1,1,1)
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

    -- create background segments: rested and normal
    local rested_bg = frame:CreateTexture(nil,"BACKGROUND")
    rested_bg:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    rested_bg:SetVertexColor(0.6,0.8,1,0.5) -- light blue
    rested_bg:SetPoint("LEFT", frame, "LEFT")
    rested_bg:SetHeight(frame:GetHeight())

    local normal_bg = frame:CreateTexture(nil,"BACKGROUND")
    normal_bg:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    normal_bg:SetVertexColor(0.5,1,0.5,0.5) -- light green
    normal_bg:SetPoint("LEFT", rested_bg, "RIGHT")
    normal_bg:SetPoint("RIGHT", frame, "RIGHT")
    normal_bg:SetHeight(frame:GetHeight())

    -- main XP fill bar on top (only occupies the upper portion of the frame)
    local bar = CreateFrame("StatusBar", nil, frame)
    bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    bar:SetHeight(24)
    bar:SetStatusBarTexture("Interface\\TARGETINGFRAME\\UI-StatusBar")
    bar:GetStatusBarTexture():SetHorizTile(false)
    bar:SetMinMaxValues(0, 100)
    bar:SetValue(0)
    bar:SetStatusBarColor(0.0,0.8,0.0)

    -- store references for updates
    frame.rested_bg = rested_bg
    frame.normal_bg = normal_bg
    frame.bar = bar

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
    -- anchor inside frame area so dragging frame still works when bar
    -- position the gold text below the XP bar
    goldtext:SetPoint("TOP", bar, "BOTTOM", 0, -2)
    goldtext:SetJustifyH("CENTER")

    -- allow clicks on the text to move the parent frame as well
    goldtext:EnableMouse(true)
    goldtext:SetScript("OnMouseDown", function()
        frame:StartMoving()
    end)
    goldtext:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        local point, relativeTo, relPoint, xOfs, yOfs = frame:GetPoint()
        xpt_global_data.ui_point = point
        xpt_global_data.ui_relPoint = relPoint
        xpt_global_data.ui_xOfs = xOfs
        xpt_global_data.ui_yOfs = yOfs
    end)

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

-- create an options panel under Interface Options or Settings
local function create_options_panel()
    local panel = CreateFrame("Frame", "XP_Timer_Options", UIParent)
    panel.name = "XP Timer"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("XP Timer Options")

    panel.showChat = CreateFrame("CheckButton", "XP_Timer_ShowChat", panel, "InterfaceOptionsCheckButtonTemplate")
    panel.showChat:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -40)
    panel.showChat.Text:SetText("Show chat messages")
    panel.showChat:SetScript("OnClick", function(self)
        xpt_global_data.show_chat = self:GetChecked()
    end)

    panel.showUI = CreateFrame("CheckButton", "XP_Timer_ShowUI", panel, "InterfaceOptionsCheckButtonTemplate")
    panel.showUI:SetPoint("TOPLEFT", panel.showChat, "BOTTOMLEFT", 0, -10)
    panel.showUI.Text:SetText("Show UI frame")
    panel.showUI:SetScript("OnClick", function(self)
        xpt_global_data.show_ui = self:GetChecked()
        if xpt_ui_frame then
            if self:GetChecked() then
                xpt_ui_frame:Show()
            else
                xpt_ui_frame:Hide()
            end
        end
    end)

    panel.showCashOnEarn = CreateFrame("CheckButton", "XP_Timer_ShowCashOnEarn", panel, "InterfaceOptionsCheckButtonTemplate")
    panel.showCashOnEarn:SetPoint("TOPLEFT", panel.showUI, "BOTTOMLEFT", 0, -10)
    panel.showCashOnEarn.Text:SetText("Show gold earned in chat messages")
    panel.showCashOnEarn:SetScript("OnClick", function(self)
        xpt_global_data.show_cash_on_earn = self:GetChecked()
    end)

    panel.cashTimeLabel = panel:CreateFontString(nil,"ARTWORK","GameFontNormal")
    panel.cashTimeLabel:SetPoint("TOPLEFT", panel.showCashOnEarn, "BOTTOMLEFT", 0, -10)
    panel.cashTimeLabel:SetText("Gold timeframe (minutes):")

    panel.cashTimeEdit = CreateFrame("EditBox", "XP_Timer_CashTimeEdit", panel, "InputBoxTemplate")
    panel.cashTimeEdit:SetSize(50, 20)
    panel.cashTimeEdit:SetPoint("LEFT", panel.cashTimeLabel, "RIGHT", 5, 0)
    panel.cashTimeEdit:SetAutoFocus(false)
    panel.cashTimeEdit:SetNumeric(true)
    panel.cashTimeEdit:SetScript("OnEditFocusLost", function(self)
        local val = tonumber(self:GetText())
        if val and val > 0 then
            xpt_global_data.cash_minute_ui_timeframe = val
            xpt:update_ui()
            self:ClearFocus()
        else
            self:SetText(xpt_global_data.cash_minute_ui_timeframe or 5)
        end
    end)

    -- Button to reset the addon UI position back to the default
    panel.resetPosition = CreateFrame("Button", "XP_Timer_ResetPosition", panel, "UIPanelButtonTemplate")
    panel.resetPosition:SetSize(150, 22)
    panel.resetPosition:SetPoint("TOPLEFT", panel.cashTimeEdit, "BOTTOMLEFT", 0, -12)
    panel.resetPosition:SetText("Reset UI Position")
    panel.resetPosition:SetScript("OnClick", function()
        xpt_global_data.ui_point = nil
        xpt_global_data.ui_relPoint = nil
        xpt_global_data.ui_xOfs = nil
        xpt_global_data.ui_yOfs = nil
        if xpt_ui_frame then
            xpt_ui_frame:ClearAllPoints()
            xpt_ui_frame:SetPoint("CENTER", 0, 0)
        end
        xpt:print("UI position reset to center")
    end)

    -- panel.cashTimeDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    -- panel.cashTimeDesc:SetPoint("TOPLEFT", panel.cashTimeLabel, "BOTTOMLEFT", 0, -4)
    -- panel.cashTimeDesc:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    -- panel.cashTimeDesc:SetJustifyH("LEFT")
    -- panel.cashTimeDesc:SetText("Gold is only tracked when you actually gain it; idle time and start and end (e.g. AFK or logged out) is ignored. The value shown is based on the most recent gain, up to the specified window, and data is retained for up to 24 hours. For example, if you go AFK for 10 minutes then return, the 5‑minute window still reflects the last minute you earned gold, not the idle period.")

    panel:SetScript("OnShow", function(self)
        panel.showChat:SetChecked(xpt_global_data.show_chat)
        panel.showUI:SetChecked(xpt_global_data.show_ui)
        if panel.showCashOnEarn then
            panel.showCashOnEarn:SetChecked(xpt_global_data.show_cash_on_earn)
        end
        if panel.cashTimeEdit then
            panel.cashTimeEdit:SetText(xpt_global_data.cash_minute_ui_timeframe or 5)
        end
    end)

    -- registration logic: prefer new Settings API when available
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
        xpt.settings_panel = panel
        xpt.settings_category = category
    else
        -- try registering the panel; if the old API isn't available yet, schedule a retry
        local function register()
            if InterfaceOptions_AddCategory then
                InterfaceOptions_AddCategory(panel)
            else
                C_Timer.After(1, register)
            end
        end
        register()
        xpt.settings_panel = panel
    end
end


-- programmatic open for settings
function xpt:OpenSettings()
    if Settings and Settings.OpenToCategory and xpt.settings_category then
        Settings.OpenToCategory(xpt.settings_category.ID)
    elseif xpt.settings_panel then
        InterfaceOptionsFrame_OpenToCategory(xpt.settings_panel)
    end
end


function xpt:update_ui()
    if not xpt_ui_frame then return end
    -- respect user setting for UI visibility
    if xpt_global_data.show_ui then
        xpt_ui_frame:Show()
    else
        xpt_ui_frame:Hide()
        -- still update currency events for the chat side
    end
   
    local xp_cur = UnitXP("player")
    local xp_max = UnitXPMax("player")

    -- if no xp can be earned or we are at max level, hide the XP bar (but keep gold text)
    local level = UnitLevel("player")
    local now = GetTime()
    xpt:updateRunningTime()
    local maxLevel = GetMaxPlayerLevel and GetMaxPlayerLevel() or 0
    -- determine if we should hide xp bar elements (max level or no xp possible)
    local hideXP = xp_max == 0 or (maxLevel>0 and level >= maxLevel)
    if hideXP then
        if xpt_ui_frame.bar then
            xpt_ui_frame.bar:Hide()
        end
        if xpt_ui_frame.text then
            xpt_ui_frame.text:Hide()
        end
        if xpt_ui_frame.rested_bg then
            xpt_ui_frame.rested_bg:Hide()
        end
        if xpt_ui_frame.normal_bg then
            xpt_ui_frame.normal_bg:Hide()
        end
        xpt_ui_frame:SetBackdropColor(0,0,0,0)
        xpt_ui_frame:SetBackdropBorderColor(0,0,0,0)
        if xpt_ui_frame.goldtext then
            xpt_ui_frame.goldtext:Show()
        end
    else
        -- ensure xp elements are visible when leveling
        if xpt_ui_frame.bar then
            xpt_ui_frame.bar:Show()
        end
        if xpt_ui_frame.text then
            xpt_ui_frame.text:Show()
        end
        if xpt_ui_frame.rested_bg then
            xpt_ui_frame.rested_bg:Show()
        end
        if xpt_ui_frame.normal_bg then
            xpt_ui_frame.normal_bg:Show()
        end
        xpt_ui_frame:SetBackdropColor(0,0,0,0.4)
        xpt_ui_frame:SetBackdropBorderColor(1,1,1,1)
    end

    --START XP BAR UPDATES
    local pct = 0
    if not hideXP and xp_max > 0 then pct = xp_cur / xp_max * 100 end
    xpt_ui_frame.bar:SetValue(pct)
    -- update rested percentage background
    local rest = GetXPExhaustion() or 0
    local restPct = 0
    if xp_max > 0 then
        restPct = math.min(rest / xp_max * 100, 100)
    end
    local totalWidth = xpt_ui_frame:GetWidth()
    if xpt_ui_frame.rested_bg then
        xpt_ui_frame.rested_bg:SetWidth(totalWidth * (restPct/100))
    end

    local time_left = 0
    local time_diff = GetTime() - self.start_time
    local xp_per_second = 0

    if time_diff > 0 then
        xp_per_second = self.xp_gained / time_diff
        if xp_per_second > 0 then
            -- if player has gained XP since last UI update, recalc base
            -- otherwise just tick down the previous estimate
            
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
    if xp_per_second > 0 and not hideXP then
        line = line .. "  " .. xp_util.to_hms_string(time_left)
    end
    xpt_ui_frame.text:SetText(line)

    local pct = 0
    if xp_max > 0 then pct = xp_cur / xp_max * 100 end
    xpt_ui_frame.bar:SetValue(pct)
    -- update rested percentage background
    local rest = GetXPExhaustion() or 0
    local restPct = 0
    if xp_max > 0 then
        restPct = math.min(rest / xp_max * 100, 100)
    end
    local totalWidth = xpt_ui_frame:GetWidth()
    if xpt_ui_frame.rested_bg then
        xpt_ui_frame.rested_bg:SetWidth(totalWidth * (restPct/100))
    end

    -- instance gold/time display
    local instanceStr = ""
    if self.in_instance and self.instance_start_time then
        local instTime = xp_util.to_hms_string(now - self.instance_start_time)
        local xp_gained_in_instance = xp_cur - (self.instance_xp_at_start or 0)
        local instance_xp_pct = 0
        if xp_max > 0 then
            instance_xp_pct = (xp_gained_in_instance / xp_max) * 100
        end
        instanceStr = "Instance gold: " .. xp_util.to_gsc_string(self.instance_gold_total) .. "  " .. instTime
                      .. "  XP: " .. string.format("%.1f%%", instance_xp_pct) .. "\n"
    end
    
    local goldstr = xp_util.to_gsc_string(xpt:cash_in_last_minutes(xpt_global_data.cash_minute_ui_timeframe or 5))

    --TODO test this
    local currencies = {}
    if xpt_character_data.currency_history then
        local sums = {}
        for i=#xpt_character_data.currency_history,1,-1 do
            local ev = xpt_character_data.currency_history[i]
            if now - ev.time <= (xpt_global_data.cash_minute_ui_timeframe or 5) * 60 then
                sums[ev.name] = (sums[ev.name] or 0) + ev.diff
            elseif now - ev.time > 86400 then
                --remove entries older than a day to prevent unbounded growth; these won't be included in the sums anyway
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
    --end currencies
    local display = instanceStr .. "Gold " .. (xpt_global_data.cash_minute_ui_timeframe or 5) .. "m: "..goldstr
    if curstr~="" then display = display.."  "..curstr end
    xpt_ui_frame.goldtext:SetText(display)
end

function xpt:trackCurrencies()
    --xpt:print("Tracking currency changes...");
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
            --xpt:print("Checking currency: ".. (info.name or "unknown") .." currencyTypesID: " .. (info.currencyTypesID or  "none") .. " currencyID " .. (info.currencyID or "none"))
            local id = info.currencyTypesID or info.currencyID
            local currency = C_CurrencyInfo.GetCurrencyInfo(id)
            if currency then
               
                local amount = currency.quantity or 0
                if xpt_character_data.currency_last_amounts[id] == nil then
                    xpt_character_data.currency_last_amounts[id] = amount
                end
                --xpt:print("xpt_character_data.currency_last_amounts[id]: " .. xpt_character_data.currency_last_amounts[id]);
                local last = xpt_character_data.currency_last_amounts[id]
                local diff = amount - last
                if diff ~= 0 then
                    table.insert(xpt_character_data.currency_history,{time=GetTime(),id=id,name=info.name,diff=diff})
                    xpt_character_data.currency_last_amounts[id] = amount
                    --xpt:print(string.format("Currency %s (id: %d) amount: %d diff: %d", info.name or "unknown", id or 0, amount, diff));
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
		xpt:print("You are in a group /xpt party to see a report")
	 	 xpt:party_start()
	end

	if not IsInGroup() and wasinparty then
		xpt:print("You left a group")
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
					   xpt:print("Unknown Command");
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
        -- ensure boolean defaults exist
        if xpt_global_data.show_chat == nil then xpt_global_data.show_chat = true end
        if xpt_global_data.show_ui == nil then xpt_global_data.show_ui = true end
        if xpt_global_data.cash_minute_ui_timeframe == nil then xpt_global_data.cash_minute_ui_timeframe = xpt_global_data_defaults.cash_minute_ui_timeframe or 5 end

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
    xpt:print("XP Timer loaded 2.0. Type '/xpt help' for more information");
	self:cash_timer_setup()
	self:reset();
	-- create floating xp bar UI
	xpt_ui_frame = create_ui()
	if not xpt_global_data.show_ui and xpt_ui_frame then
		xpt_ui_frame:Hide()
	end
	-- gather initial currency values so deltas are correct
	self:trackCurrencies()
	self:update_ui()
	-- build options panel once at login (actual registration may be deferred)
	create_options_panel()
end

function xpt:PLAYER_ENTERING_WORLD(event, isInitialLogin, isReloadingUi)
    local inInstance, instanceType = IsInInstance()
    if inInstance and not self.in_instance then
        self.in_instance = true
        self.instance_start_time = GetTime()
        self.instance_gold_total = 0        
        self.instance_xp_at_start = UnitXP("player")        
        xpt:print("Entered instance ("..(instanceType or "")..") - tracking gold and XP for this instance.")
    elseif not inInstance and self.in_instance then
        -- left instance
        self.in_instance = false
        xpt:print("Left instance, total gold: "..xp_util.to_gsc_string(self.instance_gold_total))
    end
end

function xpt:PLAYER_XP_UPDATE(...)
	local xp_cur = UnitXP("player");
	
	--Sometimes you get the event twice for a single XP grant
	if (xp_cur  == self.old_xp) then
		return;
	end
	self.xp_diff = xp_cur - self.old_xp;
	if (self.xp_diff < 0) then -- lvled up
			xpt:print("|cff00ff00Congrats on the level up|r");
		self.xp_diff = 1;
	end
	self.xp_gained = self.xp_gained + self.xp_diff;
	
	local time_diff = GetTime() - self.start_time;
	if (time_diff > 0) then
		if (xpt_global_data.show_time_on_xp) then
			local xp_last_checked_time = self.xp_checked_time;
			self.xp_checked_time = GetTime();
			local time_since_last_xp = self.xp_checked_time  - xp_last_checked_time;
			local last_estimated_time = self.time_till_next_level - time_since_last_xp;
			local xp_per_second = self.xp_gained / time_diff;
			self.time_till_next_level = (UnitXPMax("player") - xp_cur) / xp_per_second
			local estimate_inacuracy = last_estimated_time - self.time_till_next_level;
			if estimate_inacuracy > 60 then
					xpt:print(string.format("Time to next level down to: |cff00ff00%s|r",xp_util.to_hms_string(self.time_till_next_level)),0.38,0.58,0.92);
			else
				if estimate_inacuracy < -60 then
					xpt:print(string.format("Time to next level increasing: |cffff0000%s|r kill faster or change zones",xp_util.to_hms_string(self.time_till_next_level)),0.38,0.58,0.92);
				else
					xpt:print(string.format("Time to next level: %s",xp_util.to_hms_string(self.time_till_next_level)),0.38,0.58,0.92);
				end
			end
		end
	end
	self.old_xp = xp_cur;
	self:update_ui()
end

function xpt:default()
    local time_diff = GetTime() - self.start_time;
		xpt:print("Time Online: "..xp_util.to_hms_string(time_diff));
		xpt:print("XP Gained total: "..self.xp_gained);
        if (self.xp_gained == 0) then
            return
        end
		xpt:print("XP Last Gained: "..self.xp_diff);
	local xp_per_second = self.xp_gained / time_diff;
		xpt:print("XP per second: "..xp_per_second);
	local xp_cur = UnitXP("player");

	local kills_to_lvl = math.ceil((UnitXPMax("player") - xp_cur) / self.xp_diff);
		xpt:print("Kills to next level: "..kills_to_lvl);
		xpt:print(string.format("Time to next level: |cffff0000%s|r",xp_util.to_hms_string((UnitXPMax("player") - xp_cur) / xp_per_second)));
end


function xpt:hour()
    local time_diff = GetTime() - self.start_time;
	if time_diff >= (3600) then
		local xp_per_hour = (self.xp_gained / time_diff) * 3600;
			xpt:print("XP per hour: "..xp_per_hour);
	else
			xpt:print("You have not been logged in without a reset for an hour");
			xpt:print("Time Logged IN: "..xp_util.to_hms_string(time_diff));
	end
end

function xpt:updateRunningTime()
    local current_time = math.floor(GetTime());
	local cash_time_diff = current_time - self.cash_time_last_paid ;
	self.cash_time_last_paid = current_time;
	xpt_character_data.cash_running_time = xpt_character_data.cash_running_time + cash_time_diff;
end

-- We don't caount time before and after the last cash time so we just factor that out by 
function xpt:PLAYER_MONEY(...)

	    self:updateRunningTime()
        local current_cash = GetMoney(); 
		local cash_diff = current_cash - self.cash_last_known ;
		self.cash_last_known = current_cash;
	
        -- track instance gold
        if xpt_global_data["show_cash_on_earn"] then

		    if self.in_instance then
			    self.instance_gold_total = self.instance_gold_total + cash_diff
                xpt:print("Instance gold total: "..xp_util.to_gsc_string(self.instance_gold_total) .. " (+" .. xp_util.to_gsc_string(cash_diff));
            else
    			if ( cash_diff > 0) then
					xpt:print("You just made "..xp_util.to_gsc_string(cash_diff));
	    		else
					xpt:print("You just lost "..xp_util.to_gsc_string(cash_diff));		
		    	end
		    end
        end

		
		
		
		--DEFAULT_CHAT_FRAME:AddMessage("You have "..xp_util.to_gsc_string(GetMoney()));
		if (xpt_character_data.cash_values_array[xpt_character_data.cash_running_time] == nil) then
			xpt_character_data.cash_values_array[xpt_character_data.cash_running_time] = cash_diff
		else
			xpt_character_data.cash_values_array[xpt_character_data.cash_running_time] = xpt_character_data.cash_values_array[xpt_character_data.cash_running_time]+ cash_diff;
		end
        -- update UI immediately
		self:update_ui()
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

--Get the amount of cash made in the last X minutes
function xpt:cash_in_last_minutes(...)
    xpt:updateRunningTime()
    local minutes = {...}
    --xpt:print("Calculating cash in the last "..table.concat(minutes,",").." minutes...");
    if not xpt_character_data.cash_values_array then return end
    local results = {}
    for i=1,#minutes do results[i] = 0 end
    local now = xpt_character_data.cash_running_time or 0
    --xpt:print("Current cash time: "..xp_util.to_hms_string(now));
    for cash_time, cash_made in pairs(xpt_character_data.cash_values_array) do
        local timeOffset = now - cash_time
        for i, m in ipairs(minutes) do
            local ms = tonumber(m)
            if ms and timeOffset <= (ms * 60) then
                results[i] = results[i] + cash_made
            end
        end
        -- cleanup entries older than a day
        if timeOffset > 86400 then
            xpt_character_data.cash_values_array[cash_time] = nil
        end
    end
    --xpt:print("Cash in the last "..table.concat(minutes,",").." minutes: "..table.concat(results,","));
    return unpack(results)
end


function xpt:ctdefault(...)
	local timespan = ...;
	local include_timespan  = false;
	if tonumber(timespan) ~= nil then
		include_timespan = true;
		timespan = tonumber(timespan) * 60;
	elseif (timespan == "off") then
		xpt_global_data.show_cash_on_earn = false;
			xpt:print("Cash display |cffff0000disabled|r");
	elseif (timespan == "on") then
		xpt_global_data.show_cash_on_earn = true;
			xpt:print("Cash display |cff00ff00enabled|r");
	end
	
	xpt:updateRunningTime()

    local timespan_minutes = nil
    if include_timespan then timespan_minutes = timespan / 60 end
    local cash_in_last_fiveminute, cash_in_last_hour, cash_in_last_day, cash_in_timespan = xpt:cash_in_last_minutes(xpt_global_data.cash_minute_ui_timeframe or 5, 60, 1440, timespan_minutes)
    cash_in_last_fiveminute = cash_in_last_fiveminute or 0
    cash_in_last_hour = cash_in_last_hour or 0
    cash_in_last_day = cash_in_last_day or 0
    cash_in_timespan = cash_in_timespan or 0

    xpt:print("Cash in last " .. (xpt_global_data.cash_minute_ui_timeframe or 5) .. " minutes: "..xp_util.to_gsc_string(cash_in_last_fiveminute));
    xpt:print("Cash in last hour: "..xp_util.to_gsc_string(cash_in_last_hour));
    xpt:print("Cash in last day: "..xp_util.to_gsc_string(cash_in_last_day));
    if (include_timespan) then
            xpt:print(string.format("Cash in last |cff00ff00%d|r minutes: %s ",timespan/60,xp_util.to_gsc_string(cash_in_timespan)));
    end
end
function xpt:cash(...)
	xpt:ct(...)
end



function xpt:reset()
	if (self.start_time ~= nil) then
		xpt:print("XP Timer reset");
	end
	self.old_xp = UnitXP("player");
	self.start_time = GetTime(); 
	self.group_start = 0;
	self.xp_checked_time = self.start_time;
	self.time_till_next_level = 0;
	-- start with no XP gained so the UI won't show an ETA until the
	-- user actually earns experience
	self.xp_gained = 0;
	self.xp_diff = 0;

	-- UI bookkeeping for countdown logic
	self.time_left = 0;
	self.last_ui_update_time = self.start_time;
	self.last_xp_for_ui = self.old_xp;

	-- instance tracking
	self.in_instance = false
	self.instance_start_time = self.start_time
	self.instance_gold_total = 0
	check_for_join_and_leave();
    if (self.show_time_on_xp == nil) then
        xpt_global_data.show_time_on_xp = true;
	end
end

function xpt:help(msg)
		xpt:print("XP Timer Usage:");
		xpt:print("/xpt help -- this help");
		xpt:print("/xpt -- Get information about the XP you have gained");
		xpt:print("(A draggable XP bar also appears on your screen with percentage & time.)");
		xpt:print("/xpt reset -- reset your XP timer. great for you leave town or start a dungeon");
		xpt:print("/xpt hour -- xp gained average per hour if logged in for more than an hour");
		xpt:print("/xpt cash OR /ct -- show how much gold you have gained in the past 24 hours");
		xpt:print("/xpt off OR /xpt on -- disable or enable the status message on new XP");
		xpt:print("/xpt party OR /xpt group -- Find information on the current group.");
		xpt:print("/xpt party_start OR /xpt party_end -- Manually start party tracking.");
		xpt:print("/ct time -- How much gold in the last 'time' minutes. Max 24 hours");
		xpt:print("/ct on OR /ct off -- turn on (off by default) reports on gold earned to blizzard style");
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
		xpt:updateRunningTime()
        DEFAULT_CHAT_FRAME:AddMessage("Time in party for cash tracking: "..xp_util.to_hms_string(time_diff));
		local cash_in_party = select(1, xpt:cash_in_last_minutes(time_diff/60)) or 0
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

