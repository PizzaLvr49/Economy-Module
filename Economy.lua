local ProfileService = require(script.Parent.ProfileService)
local Types = require(script.Types)
local Economy = {}

-- Simple type definitions for our currencies
export type CurrencyData = {
	DisplayName: string,
	Abbreviation: string,
	SaveKey: string,
	CanBePurchased: boolean,
	CanBeEarned: boolean,
	ExchangeRateToRobux: number,
	DefaultValue: number
}

export type Currency = CurrencyData & {
	SetValue: (Currency, playerID: number, value: any) -> (),
	GetValue: (Currency, playerID: number) -> any,
	IncrementValue: (Currency, playerID: number, amount: number) -> ()
}

-- Available currencies in the game
Economy.Currencies = {
	Cash = {
		DisplayName = "Cash",
		Abbreviation = "$",
		SaveKey = "Cash",
		CanBePurchased = true,
		CanBeEarned = true,
		ExchangeRateToRobux = 10_000, -- 10k cash per robux
		DefaultValue = 1000
	},
	Gems = {
		DisplayName = "Gems",
		Abbreviation = "💎",
		SaveKey = "Gems",
		CanBePurchased = true,
		CanBeEarned = false,
		ExchangeRateToRobux = 100,
		DefaultValue = 100
	}
}

local store = ProfileService.GetProfileStore("PlayerEconomy1", { Currencies = {} })
local cache = {}

local function loadPlayerData(player)
	local key = "Player_" .. player.UserId
	local data = store:LoadProfileAsync(key)
	
	if not data then
		player:Kick("Oof! Data load failed - try again")
		return
	end
	
	if player:IsDescendantOf(game.Players) then
		data:AddUserId(player.UserId)
		data:Reconcile()
		cache[player.UserId] = data
		
		-- First time playing? Set up their wallet
		data.Data.Currencies = data.Data.Currencies or {}
	else
		data:Release()
	end
end

local function cleanupPlayerData(player)
	local data = cache[player.UserId]
	if data then
		data:Release()
		cache[player.UserId] = nil
	end
end

game.Players.PlayerAdded:Connect(loadPlayerData)
game.Players.PlayerRemoving:Connect(cleanupPlayerData)

-- Load data for players already in game
for _, player in ipairs(game.Players:GetPlayers()) do
	task.spawn(loadPlayerData, player)
end

function Economy.GetCurrency(name: string): Currency?
	return Economy.Currencies[name]
end

function Economy.PurchaseCurrency(player: Player, currencyName: string, robuxAmount: number): boolean
	local currency = Economy.Currencies[currencyName]
	if not currency or not currency.CanBePurchased then 
		return false 
	end

	-- You'd want to add your actual purchase logic here
	local success = true -- Placeholder for real transaction code
	
	if success then
		local amount = robuxAmount * currency.ExchangeRateToRobux
		currency:IncrementValue(player.UserId, amount)
		return true
	end
	return false
end

-- Sets up currency methods
local function setupCurrency(currency)
	function currency:GetValue(playerID: number)
		local data = cache[playerID]
		if not data then return 0 end
		
		if not data.Data.Currencies[self.SaveKey] then
			data.Data.Currencies[self.SaveKey] = self.DefaultValue
		end
		return data.Data.Currencies[self.SaveKey]
	end

	function currency:SetValue(playerID: number, value: any)
		local data = cache[playerID]
		if data then
			data.Data.Currencies[self.SaveKey] = value
		end
	end

	function currency:IncrementValue(playerID: number, amount: number)
		local data = cache[playerID]
		if not data then return end
		
		local current = data.Data.Currencies[self.SaveKey] or self.DefaultValue
		data.Data.Currencies[self.SaveKey] = current + amount
	end
end

for _, currency in pairs(Economy.Currencies) do
	setupCurrency(currency)
end

return Economy
